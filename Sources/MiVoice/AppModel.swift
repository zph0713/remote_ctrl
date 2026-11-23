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
    private var applyingVoiceConfig = false

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

        link.delegate = self
        buttons.delegate = self
        buttons.gestureConfiguration = { [weak self] button in
            guard let self else { return (false, false) }
            let gestures = self.settings.gestures(for: button)
            return (gestures.hasDouble, gestures.hasLong)
        }
        speech.onFinal = { [weak self] text in self?.handleFinalText(text) }
        speech.onPartial = { [weak self] text in self?.handlePartial(text) }
        speech.onError = { [weak self] message in self?.handleSpeechError(message) }
        speech.onStateChange = { [weak self] state in self?.speechState = state }
        virtualMic.onLevel = { [weak self] value in self?.virtualMicLevel = value }
        macMicMonitor.onLevel = { [weak self] value in self?.macMicLevel = value }

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

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    func stop() {
        voiceKeyMapper.restore()
        inputLock.unlock()
        virtualMic.stop()
        link.stop()
        buttons.stop()
        speech.cancel()
        hud.hide()
    }

    @objc private func applicationDidBecomeActive() {
        refreshPermissions()
        refreshDiagnostics()
        refreshAudioDevices()
        if virtualMic.deviceUID.isEmpty { configureVirtualMic() }
        if resolvedVoiceMode == .wechatIME, virtualMic.isReady, settings.lockSystemInput {
            _ = inputLock.lock(to: virtualMic.deviceUID)
        }
    }

    @objc private func systemDidWake() {
        refreshAudioDevices()
        configureVirtualMic()
        buttons.stop()
        applyVoiceModeConfiguration()
        if case .ready = linkState { return }
        link.reconnectNow()
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
        guard settings.voiceMode != .appleSpeech else {
            virtualMic.stop()
            virtualMicStatus = "Apple 离线模式（未使用虚拟麦克风）"
            return
        }
        let uid = settings.virtualDeviceUID.isEmpty
            ? (loopbackDevices.first?.uid ?? "")
            : settings.virtualDeviceUID
        guard !uid.isEmpty else {
            virtualMic.stop()
            virtualMicStatus = "未找到虚拟麦克风：请安装 BlackHole 2ch"
            return
        }
        if virtualMic.isReady, virtualMic.deviceUID == uid {
            virtualMicStatus = "已连接 \(virtualMicName(uid))"
            return
        }
        if virtualMic.configure(uid: uid) {
            virtualMicStatus = "已连接 \(virtualMicName(uid))"
        } else {
            virtualMicStatus = virtualMic.error ?? "虚拟麦克风不可用"
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
        guard !applyingVoiceConfig else { return }
        applyingVoiceConfig = true
        defer { applyingVoiceConfig = false }

        let ime = resolvedVoiceMode == .wechatIME
        guard ime else {
            voiceKeyMapper.restore()
            fnMappingStatus = "未启用（Apple 模式）"
            inputLock.unlock()
            defaultInputName = CoreAudioDeviceCatalog.defaultInputDeviceName()
            if !buttons.isSeized {
                buttons.stop()
                buttons.start(seize: true, allowActions: false)
            }
            onStatusChange?()
            return
        }

        if !virtualMic.isReady {
            refreshAudioDevices()
            configureVirtualMic()
        }
        guard virtualMic.isReady else {
            fnMappingStatus = "虚拟麦克风未就绪"
            if !buttons.isSeized {
                buttons.stop()
                buttons.start(seize: true, allowActions: false)
            }
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
                if voiceKeyMapper.hasTargets {
                    // Mapping failed while the remote is present: fall back to
                    // seize so keys do not double-trigger, but IME won't work.
                    buttons.stop()
                    buttons.start(seize: true, allowActions: false)
                    showHUD("Fn 映射失败：\(fnMappingStatus)")
                }
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
        onStatusChange?()
    }

    func reapplyVoiceMapping() {
        voiceKeyMapper.restore()
        applyVoiceModeConfiguration()
    }

    func startMacMicMonitor() {
        if macMicMonitor.isRunning {
            macMicStatus = "监听中：\(macMicMonitor.deviceName)"
            return
        }
        macMicMonitor.onLevel = { [weak self] value in self?.macMicLevel = value }
        switch macMicMonitor.authorizationStatus {
        case .authorized:
            if macMicMonitor.start() {
                macMicStatus = "监听中：\(macMicMonitor.deviceName)"
            } else {
                macMicStatus = macMicMonitor.error ?? "内建麦克风不可用"
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
        }
    }

    func stopMacMicMonitor() {
        macMicMonitor.stop()
        macMicLevel = 0
        macMicStatus = "已停止"
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

    func restartApplication() {
        let path = Bundle.main.bundlePath.replacingOccurrences(of: "'", with: "'\\''")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.8; /usr/bin/open -n '\(path)'"]
        try? task.run()
        NSApp.terminate(nil)
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
        link.reconnectNow()
    }

    func refreshDiagnostics() {
        speechDiagnostics = SpeechEngine.diagnostics(localeIdentifier: settings.localeIdentifier)
    }

    // MARK: - Voice

    private func beginVoice() {
        guard !voiceSessionActive else { return }
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
            "Apple 识别：\(speechDiagnostics)",
            "辅助功能：\(accessibilityGranted ? "已授权" : "未授权")",
            "输入监控：\(inputMonitoringGranted ? "已授权" : "未授权")",
        ].joined(separator: "\n")
    }

    func copyDiagnostics() {
        KeyInjector.copyToClipboard(diagnosticsText())
        showHUD("诊断信息已复制")
    }
}

extension AppModel: RemoteLinkDelegate {
    func remoteLink(_ link: RemoteLink, didChange state: RemoteLink.State) {
        linkState = state
        onStatusChange?()
    }

    func remoteLinkDidStartAudio(_ link: RemoteLink) {
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
        endVoice()
    }

    func remoteLink(_ link: RemoteLink, didFail message: String) {
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
        beginVoice()
    }

    func remoteButtonsDidReleaseVoice(_ buttons: RemoteButtons) {
        endVoice()
    }

    func remoteButtons(_ buttons: RemoteButtons, didChange mode: RemoteButtons.Mode) {
        hidMode = mode
        if case .ready(let seized, let actions, let devices) = mode {
            if !seized && !actions && devices > 0 {
                showHUD("未能独占遥控器：自定义按键已停用")
            }
            if devices > 0, !seized, resolvedVoiceMode == .wechatIME,
               !voiceKeyMapper.isFnMappingApplied() {
                DispatchQueue.main.async { [weak self] in
                    self?.applyVoiceModeConfiguration()
                }
            }
        }
        onStatusChange?()
    }

    func remoteButtons(_ buttons: RemoteButtons, didSeeUnknown usages: [UInt16]) {
        Log.debug("unknown HID usages: \(usages.map(String.init).joined(separator: ","))")
    }
}
