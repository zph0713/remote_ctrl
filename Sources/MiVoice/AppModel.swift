import AppKit
import Combine
import Foundation
import MiVoiceCore
import ServiceManagement
import Speech

final class AppModel: NSObject, ObservableObject {
    static let settingsKey = "settings.v1"

    @Published private(set) var settings: AppSettings
    @Published private(set) var linkState: RemoteLink.State = .idle
    @Published private(set) var hidMode: RemoteButtons.Mode = .off
    @Published private(set) var speechState: SpeechEngine.State = .idle
    @Published private(set) var speechAuthorization: SFSpeechRecognizerAuthorizationStatus
    @Published private(set) var accessibilityGranted: Bool
    @Published private(set) var inputMonitoringGranted: Bool
    @Published private(set) var isRecording = false
    @Published private(set) var speechDiagnostics = ""
    @Published private(set) var loopbackDevices: [AudioDeviceInfo] = []
    @Published private(set) var defaultInputName: String?
    @Published private(set) var virtualMicStatus = ""
    @Published private(set) var activeVoiceMode: VoiceMode = .appleSpeech
    @Published private(set) var partialTranscript = ""
    @Published private(set) var fnMappingStatus = "未启用"
    @Published private(set) var virtualMicLevel: Float = 0
    @Published private(set) var macMicLevel: Float = 0
    @Published private(set) var macMicStatus = "未启用"
    /// True after sleep/lock: every service is stopped and nothing is probed
    /// until the user chooses "恢复连接". This prevents the wake-time storm
    /// where BLE/HID/audio repeatedly fail and rebuild themselves.
    @Published private(set) var isDormant = false
    @Published var recordingButton: RemoteButton?
    @Published var recordingTrigger: ButtonTrigger = .singleClick

    var onStatusChange: (() -> Void)?

    private let link = RemoteLink()
    private let buttons = RemoteButtons()
    private let speech = SpeechEngine()
    private let hud = HUD()
    private let virtualMic = VirtualMicOutput()
    private let macMicMonitor = MacMicMonitor()
    private let inputLock = SystemInputLock()
    private let voiceKeyMapper = VoiceKeyMapper()
    private var voiceSessionActive = false
    private var sessionPeak: Float = 0
    private var warnedAccessibility = false
    private var started = false
    private var isRestarting = false
    private var applyingVoiceConfig = false
    private var isSuspended = false
    private var isResuming = false
    private var lastAutoApplyAt: TimeInterval = 0
    private var applyLimiter = BurstLimiter(window: 10, limit: 6)
    private var lastHUDText: String?
    private var lastHUDAt: TimeInterval = 0
    private var sessionLocked = false
    private var screensAsleep = false
    private var systemAsleep = false
    private var wantMacMicMonitor = false

    override init() {
        if let data = UserDefaults.standard.data(forKey: Self.settingsKey),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = decoded
        } else {
            settings = AppSettings()
        }
        speechAuthorization = SFSpeechRecognizer.authorizationStatus()
        accessibilityGranted = Permissions.accessibility
        inputMonitoringGranted = Permissions.inputMonitoring
        super.init()
    }

    func start() {
        guard !started else { return }
        started = true
        Log.step("model.start")
        Log.info(
            "settings voiceMode=\(settings.voiceMode.rawValue) " +
                "virtualDevice=\(settings.virtualDeviceUID) lockInput=\(settings.lockSystemInput)"
        )

        link.delegate = self
        buttons.delegate = self
        buttons.gestureConfiguration = { [weak self] button in
            guard let self else { return (double: false, long: false) }
            let gestures = self.settings.gestures(for: button)
            return (gestures.hasDouble, gestures.hasLong)
        }
        speech.onFinal = { [weak self] text in self?.handleFinalText(text) }
        speech.onPartial = { [weak self] text in self?.handlePartial(text) }
        speech.onError = { [weak self] message in self?.handleSpeechError(message) }
        speech.onStateChange = { [weak self] state in self?.speechState = state }
        virtualMic.onLevel = { [weak self] value in self?.virtualMicLevel = value }
        macMicMonitor.onLevel = { [weak self] value in self?.macMicLevel = value }
        macMicMonitor.onError = { [weak self] message in self?.macMicStatus = message }

        refreshDiagnostics()
        SpeechEngine.requestAuthorization { [weak self] status in
            self?.speechAuthorization = status
            self?.refreshDiagnostics()
            self?.onStatusChange?()
        }

        // Remove mappings left behind by a crash before installing new ones.
        voiceKeyMapper.resetKnownMappings()
        link.start()
        refreshPermissions()
        refreshAudioDevices()
        configureVirtualMic()
        applyVoiceModeConfiguration()
        Log.step("model.start.end")

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(
            self,
            selector: #selector(workspaceWillSleep(_:)),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        workspace.addObserver(
            self,
            selector: #selector(workspaceDidWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        workspace.addObserver(
            self,
            selector: #selector(screensDidSleep(_:)),
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )
        workspace.addObserver(
            self,
            selector: #selector(screensDidWake(_:)),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
        workspace.addObserver(
            self,
            selector: #selector(sessionDidResignActive(_:)),
            name: NSWorkspace.sessionDidResignActiveNotification,
            object: nil
        )
        workspace.addObserver(
            self,
            selector: #selector(sessionDidBecomeActive(_:)),
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )
        // NSWorkspace session notifications cover lock/unlock on current macOS;
        // the distributed pair is a fallback for display-on lock transitions.
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(
            self,
            selector: #selector(screenIsLocked(_:)),
            name: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil
        )
        distributed.addObserver(
            self,
            selector: #selector(screenIsUnlocked(_:)),
            name: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil
        )
    }

    func stop() {
        if isRestarting {
            Log.step("model.stop skipped_for_restart")
            return
        }
        Log.step("model.stop")
        voiceKeyMapper.restore()
        inputLock.unlock()
        virtualMic.stop()
        link.stop()
        buttons.stop()
        speech.cancel()
        hud.hide()
        Log.step("model.stop.end")
    }

    @objc private func applicationDidBecomeActive() {
        Log.info("app.didBecomeActive suspended=\(isSuspended) dormant=\(isDormant)")
        guard !isSuspended, !isDormant, !isResuming, !isRestarting else { return }
        refreshPermissions()
        refreshDiagnostics()
        refreshAudioDevices()
        if virtualMic.deviceUID.isEmpty { configureVirtualMic() }
        if resolvedVoiceMode == .wechatIME, virtualMic.isReady, settings.lockSystemInput {
            _ = inputLock.lock(to: virtualMic.deviceUID)
        }
    }

    @objc private func workspaceWillSleep(_ notification: Notification) {
        Log.info("workspace.event willSleep")
        onMain { [weak self] in
            self?.systemAsleep = true
            self?.updateSuspension()
        }
    }

    @objc private func workspaceDidWake(_ notification: Notification) {
        Log.info("workspace.event didWake")
        onMain { [weak self] in
            self?.systemAsleep = false
            self?.updateSuspension()
        }
    }

    @objc private func screensDidSleep(_ notification: Notification) {
        Log.info("workspace.event screensDidSleep")
        onMain { [weak self] in
            self?.screensAsleep = true
            self?.updateSuspension()
        }
    }

    @objc private func screensDidWake(_ notification: Notification) {
        Log.info("workspace.event screensDidWake")
        onMain { [weak self] in
            self?.screensAsleep = false
            self?.updateSuspension()
        }
    }

    @objc private func sessionDidResignActive(_ notification: Notification) {
        Log.info("workspace.event sessionDidResignActive")
        onMain { [weak self] in
            self?.sessionLocked = true
            self?.updateSuspension()
        }
    }

    @objc private func sessionDidBecomeActive(_ notification: Notification) {
        Log.info("workspace.event sessionDidBecomeActive")
        onMain { [weak self] in
            self?.sessionLocked = false
            self?.updateSuspension()
        }
    }

    @objc private func screenIsLocked(_ notification: Notification) {
        Log.info("workspace.event screenIsLocked")
        onMain { [weak self] in
            self?.sessionLocked = true
            self?.updateSuspension()
        }
    }

    @objc private func screenIsUnlocked(_ notification: Notification) {
        Log.info("workspace.event screenIsUnlocked")
        onMain { [weak self] in
            self?.sessionLocked = false
            self?.updateSuspension()
        }
    }

    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }

    private func updateSuspension() {
        let shouldSuspend = sessionLocked || screensAsleep || systemAsleep
        Log.info(
            "suspension.update lock=\(sessionLocked) screens=\(screensAsleep) " +
                "system=\(systemAsleep) suspended=\(isSuspended) shouldSuspend=\(shouldSuspend)"
        )
        if shouldSuspend {
            suspendForSleep()
        } else if isDormant {
            // Deliberately do not wake anything up. After a lid-open the BLE,
            // HID and CoreAudio stacks can be half-initialized; rebuilding them
            // immediately caused a failure/rebuild storm. Stay dormant until
            // the user explicitly chooses "恢复连接".
            Log.info("resume.skipped dormant=true")
        } else {
            Log.info("resume.skipped not_suspended")
        }
    }

    /// Release every wake-capable resource before the Mac sleeps or locks:
    /// audio engines, BLE, HID, Fn remapping and the system input override.
    private func suspendForSleep() {
        guard !isSuspended else { return }
        isSuspended = true
        isResuming = false
        isDormant = true
        applyLimiter.reset()
        // Decide before stopping the virtual mic: in automatic mode
        // resolvedVoiceMode falls back to Apple once the mic is stopped.
        let wasIME = resolvedVoiceMode == .wechatIME
        Log.step(
            "suspend.begin sessionLocked=\(sessionLocked) screensAsleep=\(screensAsleep) " +
                "systemAsleep=\(systemAsleep) mode=\(settings.voiceMode.rawValue)"
        )
        voiceSessionActive = false
        isRecording = false
        activeVoiceMode = .appleSpeech

        Log.step("suspend.hud.hide")
        hud.hide()

        Log.step("suspend.speech.cancel")
        speech.cancel()

        Log.step("suspend.virtualMic.stop")
        virtualMic.stop()

        Log.step("suspend.link.stop")
        link.stop()

        Log.step("suspend.buttons.stop")
        buttons.stop()

        Log.step("suspend.fn.restore")
        let restored = voiceKeyMapper.restore()
        Log.info("suspend.fn.restore result=\(restored) error=\(voiceKeyMapper.error ?? "none")")

        Log.step("suspend.input")
        // In IME mode keep the loopback selected: WeChat Input caches its
        // input device, and switching back to the built-in mic here makes it
        // record from the wrong device after resume. Apple mode has no such
        // cache and gets the original input restored.
        if !wasIME {
            inputLock.unlock()
        }
        defaultInputName = CoreAudioDeviceCatalog.defaultInputDeviceName()
        Log.info(
            "suspend.input mode=\(settings.voiceMode.rawValue) wasIME=\(wasIME) " +
                "default=\(defaultInputName ?? "nil")"
        )

        Log.step("suspend.macMic.stop")
        macMicMonitor.stop()
        macMicLevel = 0
        macMicStatus = "已暂停（屏幕锁定/休眠）"
        Log.step("suspend.end dormant=true")
        onStatusChange?()
        Log.flush()
    }

    /// Explicit wake-up from the dormant state. A fresh process is the only
    /// reliable way to recover from a half-initialized BLE/HID/CoreAudio stack
    /// after sleep, so restart the app; fall back to an in-place resume only if
    /// the helper process cannot be spawned.
    func resumeFromDormant() {
        guard isDormant else {
            Log.info("resume.manual skipped not_dormant")
            link.reconnectNow()
            return
        }
        Log.info("resume.manual mode=restart")
        if restartApplication() {
            return
        }
        Log.error("app.restart result=spawn_failed fallback=in_place")
        resumeInPlace()
    }

    /// Restart MiVoice by launching a detached helper that waits for this
    /// process to exit and then opens a new instance. Returns false only when
    /// the helper cannot be started; the caller may fall back to `resumeInPlace`.
    @discardableResult
    func restartApplication() -> Bool {
        guard !isRestarting else { return true }
        isRestarting = true
        Log.step("app.restart begin")
        // In the dormant path these are already stopped; calling them again is
        // cheap and also makes an explicit restart while active safe.
        virtualMic.stop()
        link.stop()
        buttons.stop()
        speech.cancel()
        hud.hide()
        Log.flush()

        let appPath = Bundle.main.bundleURL.path
        guard FileManager.default.fileExists(atPath: appPath) else {
            Log.error("app.restart missing_bundle path=\(appPath)")
            isRestarting = false
            showHUD("找不到 MiVoice.app，无法自动重启")
            return false
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let logDirectory = Log.directoryURL.path
        let relaunchLog = Log.directoryURL.appendingPathComponent("relaunch.log").path
        let script = """
        #!/bin/sh
        trap '' HUP
        mkdir -p \(shellQuote(logDirectory))
        exec >>\(shellQuote(relaunchLog)) 2>&1
        echo "relaunch $(date '+%Y-%m-%d %H:%M:%S') old_pid=\(pid) app="\(shellQuote(appPath))
        n=0
        while kill -0 \(pid) 2>/dev/null; do
          n=$((n+1))
          if [ "$n" -ge 200 ]; then
            if /bin/ps -p \(pid) -o comm= 2>/dev/null | /usr/bin/grep -q MiVoice; then
              echo "old process did not exit; sending SIGKILL"
              kill -9 \(pid) 2>/dev/null
            fi
            sleep 1
            break
          fi
          sleep 0.1
        done
        /usr/bin/open -n \(shellQuote(appPath))
        echo "open_exit=$?"
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            Log.error("app.restart spawn_failed error=\(error.localizedDescription)")
            isRestarting = false
            showHUD("自动重启失败：\(error.localizedDescription)")
            return false
        }
        Log.info("app.restart helper_started pid=\(pid)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.terminate(nil)
        }
        return true
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// In-place fallback used only when the helper process cannot be spawned.
    private func resumeInPlace() {
        guard !isResuming else {
            Log.info("resume.manual skipped resuming")
            return
        }
        guard isDormant else {
            Log.info("resume.manual skipped not_dormant")
            link.reconnectNow()
            return
        }
        isDormant = false
        isSuspended = false
        isResuming = true
        applyLimiter.reset()
        sessionLocked = false
        screensAsleep = false
        systemAsleep = false
        Log.step("resume.manual delay_ms=600")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, !self.isDormant, !self.isSuspended else {
                Log.info("resume.manual cancelled")
                self?.isResuming = false
                return
            }
            let begin = ProcessInfo.processInfo.systemUptime
            Log.step("resume.begin")
            self.refreshPermissions()
            Log.info(
                "resume.permissions accessibility=\(self.accessibilityGranted) " +
                    "inputMonitoring=\(self.inputMonitoringGranted)"
            )

            Log.step("resume.refreshAudio")
            self.refreshAudioDevices()
            Log.info(
                "resume.audioDevices loopback=\(self.loopbackDevices.count) " +
                    "default=\(self.defaultInputName ?? "nil")"
            )

            Log.step("resume.configureVirtualMic")
            self.configureVirtualMic()

            Log.step("resume.link.start")
            self.link.start()

            Log.step("resume.applyVoiceMode")
            self.applyVoiceModeConfiguration()

            if self.wantMacMicMonitor {
                Log.step("resume.macMic.start")
                self.startMacMicMonitor()
            }
            self.onStatusChange?()
            let elapsed = Int((ProcessInfo.processInfo.systemUptime - begin) * 1_000)
            Log.step("resume.end elapsed_ms=\(elapsed) virtualMic=\(self.virtualMicStatus) " +
                "hid=\(self.hidMode.text) link=\(self.linkState.text) mic=\(self.macMicStatus)")
            self.isResuming = false
            Log.flush()
        }
    }

    // MARK: - Settings

    func setBinding(
        _ binding: ButtonBinding,
        for button: RemoteButton,
        trigger: ButtonTrigger = .singleClick
    ) {
        var copy = settings
        copy.setBinding(binding, for: button, trigger: trigger)
        settings = copy
        saveSettings()
    }

    func setLocale(_ identifier: String) {
        var copy = settings
        copy.localeIdentifier = identifier
        settings = copy
        saveSettings()
        refreshDiagnostics()
    }

    func setShowHUD(_ value: Bool) {
        var copy = settings
        copy.showHUD = value
        settings = copy
        saveSettings()
    }

    func setRestoreClipboard(_ value: Bool) {
        var copy = settings
        copy.restoreClipboard = value
        settings = copy
        saveSettings()
    }

    func setVoiceMode(_ mode: VoiceMode) {
        Log.info("settings.voiceMode=\(mode.rawValue)")
        var copy = settings
        copy.voiceMode = mode
        settings = copy
        saveSettings()
        configureVirtualMic()
        applyVoiceModeConfiguration()
        onStatusChange?()
    }

    func setVirtualDevice(_ uid: String) {
        var copy = settings
        copy.virtualDeviceUID = uid
        settings = copy
        saveSettings()
        configureVirtualMic()
        applyVoiceModeConfiguration()
    }

    func setLockSystemInput(_ value: Bool) {
        var copy = settings
        copy.lockSystemInput = value
        settings = copy
        saveSettings()
        guard !isDormant, !isSuspended else { return }
        if value, resolvedVoiceMode == .wechatIME, virtualMic.isReady {
            _ = inputLock.lock(to: virtualMic.deviceUID)
        } else if !value {
            inputLock.unlock()
        }
        defaultInputName = CoreAudioDeviceCatalog.defaultInputDeviceName()
    }

    func refreshAudioDevices() {
        loopbackDevices = CoreAudioDeviceCatalog.loopbackDevices()
        defaultInputName = CoreAudioDeviceCatalog.defaultInputDeviceName()
        if !loopbackDevices.contains(where: { $0.uid == settings.virtualDeviceUID }) {
            var copy = settings
            copy.virtualDeviceUID = loopbackDevices.first?.uid ?? ""
            settings = copy
            saveSettings()
        }
    }

    func configureVirtualMic() {
        Log.step("virtualMic.configure")
        guard !isDormant, !isSuspended, !isRestarting else {
            virtualMicStatus = "已休眠（恢复连接后启用）"
            Log.info("virtualMic.configure skipped dormant=\(isDormant) suspended=\(isSuspended)")
            return
        }
        guard settings.voiceMode != .appleSpeech else {
            virtualMic.stop()
            virtualMicStatus = "Apple 离线模式（未使用虚拟麦克风）"
            Log.info("virtualMic.configure result=apple_mode")
            return
        }
        let uid = settings.virtualDeviceUID.isEmpty
            ? (loopbackDevices.first?.uid ?? "")
            : settings.virtualDeviceUID
        guard !uid.isEmpty else {
            virtualMic.stop()
            virtualMicStatus = "未找到虚拟麦克风：请安装 BlackHole 2ch"
            Log.error("virtualMic.configure result=no_device")
            return
        }
        if virtualMic.isReady, virtualMic.deviceUID == uid {
            virtualMicStatus = "已连接 \(virtualMicName(uid))"
            Log.info("virtualMic.configure result=already_ready uid=\(uid)")
            return
        }
        let ok = virtualMic.configure(uid: uid)
        if ok {
            virtualMicStatus = "已连接 \(virtualMicName(uid))"
            Log.info("virtualMic.configure result=ready uid=\(uid)")
        } else {
            virtualMicStatus = virtualMic.error ?? "虚拟麦克风不可用"
            Log.error("virtualMic.configure result=failed uid=\(uid) error=\(virtualMicStatus)")
        }
        onStatusChange?()
    }

    func virtualMicName(_ uid: String) -> String {
        loopbackDevices.first(where: { $0.uid == uid })?.name ?? "虚拟麦克风"
    }

    var selectedVirtualDeviceName: String {
        if settings.virtualDeviceUID.isEmpty { return "未选择" }
        return virtualMicName(settings.virtualDeviceUID)
    }

    var voiceStatusText: String {
        if isDormant { return "已深度休眠（点按恢复会重启 MiVoice）" }
        if resolvedVoiceMode == .wechatIME {
            return virtualMic.isReady ? "微信输入法 · \(fnMappingStatus)" : "微信输入法 · 虚拟麦克风未就绪"
        }
        return "Apple 离线识别 · \(SpeechEngine.authorizationText())"
    }

    var resolvedVoiceMode: VoiceMode {
        switch settings.voiceMode {
        case .appleSpeech: return .appleSpeech
        case .wechatIME: return .wechatIME
        case .automatic: return virtualMic.isReady ? .wechatIME : .appleSpeech
        }
    }

    func applyVoiceModeConfiguration() {
        guard !isDormant, !isSuspended, !isRestarting else {
            Log.info("voiceMode.apply skipped dormant=\(isDormant) suspended=\(isSuspended)")
            return
        }
        guard !applyingVoiceConfig else { return }
        applyingVoiceConfig = true
        defer { applyingVoiceConfig = false }

        // Circuit breaker: if configuration is being re-entered in a burst,
        // stop every service instead of letting a failure/rebuild loop take
        // the main thread down. The user can resume deliberately.
        let now = ProcessInfo.processInfo.systemUptime
        if applyLimiter.shouldBlock(at: now) {
            Log.error("voiceMode.apply circuit_breaker attempts=\(applyLimiter.count)")
            suspendForSleep()
            showHUD("配置反复失败，MiVoice 已休眠；请从菜单恢复连接")
            onStatusChange?()
            return
        }

        let ime = resolvedVoiceMode == .wechatIME
        Log.info(
            "voiceMode.apply begin setting=\(settings.voiceMode.rawValue) " +
                "resolved=\(resolvedVoiceMode.rawValue) virtualMic=\(virtualMic.isReady)"
        )
        guard ime else {
            voiceKeyMapper.restore()
            fnMappingStatus = "未启用（Apple 模式）"
            inputLock.unlock()
            defaultInputName = CoreAudioDeviceCatalog.defaultInputDeviceName()
            if !buttons.isSeized {
                buttons.stop()
                buttons.start(seize: true, allowActions: false)
            }
            Log.info("voiceMode.apply result=apple_mode")
            onStatusChange?()
            return
        }

        if !virtualMic.isReady {
            refreshAudioDevices()
            configureVirtualMic()
        }
        guard virtualMic.isReady else {
            Log.error("voiceMode.apply result=virtual_mic_not_ready")
            fnMappingStatus = "虚拟麦克风未就绪"
            // Do not rebuild HID here either: when the virtual mic is missing
            // the device-added callback can re-enter this path. Leave the
            // current manager alone and let the user fix the audio device.
            inputLock.unlock()
            onStatusChange?()
            return
        }

        // The system-level Fn mapping only works when we do not seize the HID
        // interface. Ordinary buttons are mapped to 0 by VoiceKeyMapper, so
        // MiVoice can still handle them without native double actions.
        if buttons.isSeized {
            buttons.stop()
        }
        if !buttons.isActionsEnabled {
            buttons.stop()
            buttons.start(seize: false, allowActions: true)
            if case .failed(let message) = buttons.mode {
                fnMappingStatus = message
                onStatusChange?()
                return
            }
        }

        if !voiceKeyMapper.isFnMappingApplied() {
            if !voiceKeyMapper.applyFnMapping() {
                fnMappingStatus = voiceKeyMapper.error ?? "Fn 映射失败"
                Log.error("voiceMode.apply mapping_failed error=\(fnMappingStatus)")
                // Do not tear down and rebuild the HID manager here. A failed
                // mapping after wake used to fall back to seize, which failed
                // again and re-triggered this path in a tight loop (HUD spam
                // and a frozen main thread). Keep the monitor-only manager and
                // report once; the next user action can retry explicitly.
                showHUD("Fn 映射失败：\(fnMappingStatus)")
                onStatusChange?()
                return
            }
        }
        fnMappingStatus = "已映射 F5 → Fn"
        if settings.lockSystemInput {
            _ = inputLock.lock(to: virtualMic.deviceUID)
        } else {
            inputLock.unlock()
        }
        defaultInputName = CoreAudioDeviceCatalog.defaultInputDeviceName()
        Log.info(
            "voiceMode.apply end mapping=\(fnMappingStatus) hid=\(buttons.mode.text) " +
                "input=\(defaultInputName ?? "nil") lock=\(settings.lockSystemInput)"
        )
        onStatusChange?()
    }

    func reapplyVoiceMapping() {
        voiceKeyMapper.restore()
        applyVoiceModeConfiguration()
    }

    func startMacMicMonitor() {
        Log.step("macMic.start")
        wantMacMicMonitor = true
        guard !isSuspended, !isDormant else {
            macMicStatus = "已休眠（点按恢复连接后启用）"
            return
        }
        if macMicMonitor.isRunning {
            macMicStatus = "监听中：\(macMicMonitor.deviceName)"
            return
        }
        macMicMonitor.onLevel = { [weak self] value in self?.macMicLevel = value }
        macMicMonitor.onError = { [weak self] message in self?.macMicStatus = message }
        switch macMicMonitor.authorizationStatus {
        case .authorized:
            let ok = macMicMonitor.start()
            if ok {
                macMicStatus = "监听中：\(macMicMonitor.deviceName)"
                Log.info("macMic.start result=ready device=\(macMicMonitor.deviceName)")
            } else {
                macMicStatus = macMicMonitor.error ?? "内建麦克风不可用"
                Log.error("macMic.start result=failed error=\(macMicStatus)")
            }
        case .notDetermined:
            macMicStatus = "等待麦克风授权…"
            macMicMonitor.requestAccess { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted {
                        self.startMacMicMonitor()
                    } else {
                        self.macMicStatus = "未授权麦克风"
                    }
                }
            }
        default:
            macMicStatus = "未授权麦克风（系统设置 → 隐私与安全性 → 麦克风）"
            macMicLevel = 0
            Log.error("macMic.start result=denied")
        }
    }

    func requestMacMicAccess() {
        switch macMicMonitor.authorizationStatus {
        case .authorized:
            startMacMicMonitor()
        case .notDetermined:
            macMicMonitor.requestAccess { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted {
                        self.startMacMicMonitor()
                    } else {
                        self.macMicStatus = "未授权麦克风"
                    }
                }
            }
        default:
            macMicStatus = "未授权麦克风（系统设置 → 隐私与安全性 → 麦克风）"
            Permissions.open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        }
    }

    func stopMacMicMonitor() {
        if isRestarting { return }
        Log.step("macMic.stop")
        wantMacMicMonitor = false
        macMicMonitor.stop()
        macMicLevel = 0
        macMicStatus = "已停止"
        Log.info("macMic.stop result=stopped")
    }

    func testVirtualMic() {
        if !virtualMic.isReady {
            refreshAudioDevices()
            configureVirtualMic()
        }
        guard virtualMic.isReady else {
            showHUD(virtualMicStatus)
            return
        }
        virtualMic.playTestTone()
        showHUD("已向虚拟麦克风播放测试音")
    }

    func openSoundSettings() {
        Permissions.open("x-apple.systempreferences:com.apple.preference.sound")
    }

    func setLaunchAtLogin(_ value: Bool) {
        do {
            if value {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.error("login item update failed: \(error.localizedDescription)")
            lastError("登录时启动设置失败，请把应用放在“应用程序”目录后重试")
        }
        var copy = settings
        copy.launchAtLogin = SMAppService.mainApp.status == .enabled
        settings = copy
        saveSettings()
    }

    private func saveSettings() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: Self.settingsKey)
    }

    // MARK: - Permissions

    func refreshPermissions() {
        accessibilityGranted = Permissions.accessibility
        inputMonitoringGranted = Permissions.inputMonitoring
        speechAuthorization = SFSpeechRecognizer.authorizationStatus()
        onStatusChange?()
    }

    func requestAccessibility() {
        Permissions.requestAccessibility()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            self.refreshPermissions()
        }
    }

    func requestInputMonitoring() {
        Permissions.requestInputMonitoring()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            self.refreshPermissions()
        }
    }

    func requestSpeechAuthorization() {
        if speechAuthorization == .denied {
            Permissions.open("x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
            return
        }
        SpeechEngine.requestAuthorization { [weak self] status in
            self?.speechAuthorization = status
            self?.refreshDiagnostics()
        }
    }

    func retryButtons() {
        buttons.stop()
        applyVoiceModeConfiguration()
    }

    func reconnectRemote() {
        if isDormant {
            resumeFromDormant()
        } else {
            link.reconnectNow()
        }
    }

    func refreshDiagnostics() {
        speechDiagnostics = SpeechEngine.diagnostics(localeIdentifier: settings.localeIdentifier)
    }

    // MARK: - Voice

    private func beginVoice() {
        guard !voiceSessionActive else { return }
        guard !isDormant, !isSuspended, !isResuming, !isRestarting else {
            Log.info("voice.begin skipped dormant=\(isDormant) suspended=\(isSuspended)")
            return
        }
        Log.info("voice.begin resolved=\(resolvedVoiceMode.rawValue)")
        guard case .ready = linkState else {
            showHUD("遥控器未连接")
            return
        }
        var mode = resolvedVoiceMode
        if mode == .wechatIME || settings.voiceMode == .automatic {
            if !virtualMic.isReady {
                refreshAudioDevices()
                configureVirtualMic()
            }
            mode = resolvedVoiceMode
        }
        guard mode == .wechatIME else {
            startAppleVoice()
            return
        }
        guard virtualMic.isReady else {
            if settings.voiceMode == .automatic {
                startAppleVoice()
            } else {
                showHUD(virtualMic.error ?? "虚拟麦克风不可用")
            }
            return
        }

        // The remote's F5 is mapped to Fn at the HID level, so macOS and the
        // input method receive a real Fn hold. Do not synthesize a second Fn.
        if !voiceKeyMapper.isFnMappingApplied() {
            applyVoiceModeConfiguration()
        }
        guard voiceKeyMapper.isFnMappingApplied() else {
            showHUD("Fn 映射未生效：\(fnMappingStatus)")
            return
        }

        voiceSessionActive = true
        isRecording = true
        activeVoiceMode = .wechatIME
        _ = link.sendMicrophoneOpen()

        if settings.lockSystemInput {
            _ = inputLock.lock(to: virtualMic.deviceUID)
            defaultInputName = CoreAudioDeviceCatalog.defaultInputDeviceName()
        }
        sessionPeak = 0
        hud.hide()
        virtualMic.beginSession()
        onStatusChange?()
    }

    private func startAppleVoice() {
        voiceSessionActive = true
        isRecording = true
        activeVoiceMode = .appleSpeech
        partialTranscript = ""
        _ = link.sendMicrophoneOpen()

        if speech.start(localeIdentifier: settings.localeIdentifier) {
            showHUD("正在听…", sticky: true)
        } else {
            voiceSessionActive = false
            isRecording = false
            activeVoiceMode = .appleSpeech
            link.sendMicrophoneClose()
        }
        onStatusChange?()
    }

    private func endVoice() {
        guard voiceSessionActive else { return }
        Log.info("voice.end active=\(activeVoiceMode.rawValue)")
        voiceSessionActive = false
        isRecording = false
        link.sendMicrophoneClose()

        switch activeVoiceMode {
        case .wechatIME:
            // The physical Fn-up already stopped the input method when the
            // remote key was released; just let any queued audio finish.
            activeVoiceMode = .appleSpeech
        case .appleSpeech, .automatic:
            if speechState == .listening {
                speech.finish()
                showHUD(
                    "识别中…",
                    detail: partialTranscript.isEmpty ? nil : transcriptTail(partialTranscript),
                    sticky: true
                )
            } else {
                hud.hide()
            }
            activeVoiceMode = .appleSpeech
        }
        onStatusChange?()
    }

    private func handleFinalText(_ text: String) {
        partialTranscript = ""
        let result = KeyInjector.insertText(text, restoreClipboard: settings.restoreClipboard)
        switch result {
        case .pasted:
            showHUD("已输入 \(text.count) 字")
        case .copied:
            if accessibilityGranted {
                showHUD("已复制到剪贴板")
            } else {
                showHUD("已复制；授权辅助功能后可自动粘贴")
            }
        case .failed:
            showHUD("输入失败")
        }
    }

    private func handleSpeechError(_ message: String) {
        partialTranscript = ""
        showHUD(message)
        lastError(message)
    }

    private func handlePartial(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        partialTranscript = trimmed
        guard activeVoiceMode == .appleSpeech, isRecording else { return }
        guard !trimmed.isEmpty else {
            showHUD("正在听…", sticky: true)
            return
        }
        showHUD("正在听…", detail: transcriptTail(trimmed), sticky: true)
    }

    private func transcriptTail(_ text: String) -> String {
        let limit = 180
        guard text.count > limit else { return text }
        return "…" + String(text.suffix(limit))
    }

    private func lastError(_ message: String) {
        Log.error("app error: \(message)")
    }

    private func showHUD(_ message: String, detail: String? = nil, sticky: Bool = false) {
        guard settings.showHUD else { return }
        if detail == nil, !sticky {
            let now = ProcessInfo.processInfo.systemUptime
            if message == lastHUDText, now - lastHUDAt < 5 {
                return
            }
            lastHUDText = message
            lastHUDAt = now
        }
        hud.show(message, detail: detail, sticky: sticky)
    }

    // MARK: - Diagnostics

    func diagnosticsText() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return [
            "MiVoice \(version) (\(build))",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "遥控器：\(linkState.text)",
            "按键通道：\(hidMode.text)",
            "语音方式：\(settings.voiceMode.title)（当前：\(resolvedVoiceMode.title)）",
            "虚拟麦克风：\(virtualMicStatus)",
            "系统输入：\(defaultInputName ?? "未知")",
            "Fn 映射：\(fnMappingStatus)",
            "最近语音峰值：\(String(format: "%.4f", sessionPeak))",
            "挂起：\(isSuspended) 深度休眠：\(isDormant) lock=\(sessionLocked) " +
                "screens=\(screensAsleep) system=\(systemAsleep)",
            "日志：\(Log.fileURL.path)（当前步骤：\(Log.currentStep)）",
            "Apple 识别：\(speechDiagnostics)",
            "辅助功能：\(accessibilityGranted ? "已授权" : "未授权")",
            "输入监控：\(inputMonitoringGranted ? "已授权" : "未授权")",
        ].joined(separator: "\n")
    }

    func copyDiagnostics() {
        KeyInjector.copyToClipboard(diagnosticsText())
        showHUD("诊断信息已复制")
    }

    func openLogFolder() {
        NSWorkspace.shared.open(Log.directoryURL)
    }

    func exportDiagnostics() {
        Log.step("diagnostics.export")
        let info = diagnosticsText()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Log.exportBundle(systemInfo: info)
            DispatchQueue.main.async {
                guard let self else { return }
                if let url = result {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                    self.showHUD("诊断日志已导出")
                    Log.info("diagnostics.export result=ok path=\(url.path)")
                } else {
                    self.showHUD("导出失败，请打开日志文件夹")
                    Log.error("diagnostics.export result=failed")
                }
            }
        }
    }
}

extension AppModel: RemoteLinkDelegate {
    func remoteLink(_ link: RemoteLink, didChange state: RemoteLink.State) {
        linkState = state
        Log.info("link.state \(state.text)")
        onStatusChange?()
    }

    func remoteLinkDidStartAudio(_ link: RemoteLink) {
        Log.info("link.audioStarted")
        beginVoice()
    }

    func remoteLink(_ link: RemoteLink, didDecode samples: [Int16]) {
        if activeVoiceMode == .wechatIME {
            virtualMic.enqueue(samples)
            sessionPeak = max(sessionPeak, virtualMic.level)
        } else {
            speech.append(samples)
        }
    }

    func remoteLinkDidStopAudio(_ link: RemoteLink) {
        Log.info("link.audioStopped")
        endVoice()
    }

    func remoteLink(_ link: RemoteLink, didFail message: String) {
        Log.error("link.failed \(message)")
        if activeVoiceMode == .wechatIME {
            activeVoiceMode = .appleSpeech
            virtualMic.cancelDrain()
        } else if voiceSessionActive {
            speech.finish()
        }
        lastError(message)
        onStatusChange?()
    }
}

extension AppModel: RemoteButtonsDelegate {
    func remoteButtons(_ buttons: RemoteButtons, didTrigger button: RemoteButton, trigger: ButtonTrigger) {
        let binding = settings.binding(for: button, trigger: trigger)
        Log.info("button.trigger \(button.rawValue) \(trigger.rawValue) kind=\(binding.kind.rawValue)")
        guard binding.kind != .none else { return }
        if !accessibilityGranted &&
            (binding.kind == .preset || binding.kind == .shortcut || binding.kind == .text) {
            if !warnedAccessibility {
                warnedAccessibility = true
                showHUD("请授权辅助功能以发送按键")
            }
            return
        }
        KeyInjector.perform(binding, restoreClipboard: settings.restoreClipboard)
    }

    func remoteButtonsDidPressVoice(_ buttons: RemoteButtons) {
        Log.info("voice.press")
        beginVoice()
    }

    func remoteButtonsDidReleaseVoice(_ buttons: RemoteButtons) {
        Log.info("voice.release")
        endVoice()
    }

    func remoteButtons(_ buttons: RemoteButtons, didChange mode: RemoteButtons.Mode) {
        hidMode = mode
        if case .ready(let seized, let actions, let devices) = mode {
            if !seized && !actions && devices > 0 {
                showHUD("未能独占遥控器：自定义按键已停用")
            }
            if devices > 0, !seized, !isDormant, !isSuspended,
               resolvedVoiceMode == .wechatIME,
               !voiceKeyMapper.isFnMappingApplied() {
                // Device-added notifications can arrive in a burst after wake.
                // Retry at most once every few seconds; applyVoiceModeConfiguration
                // no longer rebuilds the manager on mapping failure, so this
                // cannot turn into a stop/start loop.
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastAutoApplyAt > 8 {
                    lastAutoApplyAt = now
                    DispatchQueue.main.async { [weak self] in
                        self?.applyVoiceModeConfiguration()
                    }
                }
            }
        }
        onStatusChange?()
    }

    func remoteButtons(_ buttons: RemoteButtons, didSeeUnknown usages: [UInt16]) {
        Log.debug("unknown HID usages: \(usages.map(String.init).joined(separator: ","))")
    }
}
