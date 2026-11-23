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
    @Published var recordingButton: RemoteButton?

    var onStatusChange: (() -> Void)?

    private let link = RemoteLink()
    private let buttons = RemoteButtons()
    private let speech = SpeechEngine()
    private let hud = HUD()
    private let virtualMic = VirtualMicOutput()
    private let inputLock = SystemInputLock()
    private let fnTrigger = FnTrigger()
    private var voiceSessionActive = false
    private var warnedAccessibility = false
    private var started = false
    private var imeGeneration: UInt64 = 0
    private var imeReleaseWork: DispatchWorkItem?

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
        speech.onFinal = { [weak self] text in self?.handleFinalText(text) }
        speech.onError = { [weak self] message in self?.handleSpeechError(message) }
        speech.onStateChange = { [weak self] state in self?.speechState = state }

        refreshDiagnostics()
        SpeechEngine.requestAuthorization { [weak self] status in
            self?.speechAuthorization = status
            self?.refreshDiagnostics()
            self?.onStatusChange?()
        }

        link.start()
        buttons.start()
        refreshPermissions()
        refreshAudioDevices()
        configureVirtualMic()

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
        imeReleaseWork?.cancel()
        imeReleaseWork = nil
        imeGeneration &+= 1
        fnTrigger.release()
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
    }

    @objc private func systemDidWake() {
        if !buttons.mode.isSeized {
            buttons.stop()
            buttons.start()
        }
        refreshAudioDevices()
        configureVirtualMic()
        if case .ready = linkState { return }
        link.reconnectNow()
    }

    // MARK: - Settings

    func setBinding(_ binding: ButtonBinding, for button: RemoteButton) {
        var copy = settings
        copy.setBinding(binding, for: button)
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
        if activeVoiceMode == .wechatIME {
            finishIME(token: imeGeneration)
        }
        var copy = settings
        copy.voiceMode = mode
        settings = copy
        saveSettings()
        configureVirtualMic()
        onStatusChange?()
    }

    func setVirtualDevice(_ uid: String) {
        if activeVoiceMode == .wechatIME {
            finishIME(token: imeGeneration)
        }
        var copy = settings
        copy.virtualDeviceUID = uid
        settings = copy
        saveSettings()
        configureVirtualMic()
    }

    func setLockSystemInput(_ value: Bool) {
        var copy = settings
        copy.lockSystemInput = value
        settings = copy
        saveSettings()
        if !value { inputLock.unlock() }
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
            return virtualMic.isReady ? "微信输入法 · 虚拟麦克风就绪" : "微信输入法 · 虚拟麦克风未就绪"
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

    func testIMETrigger() {
        if !virtualMic.isReady {
            refreshAudioDevices()
            configureVirtualMic()
        }
        guard fnTrigger.press() else {
            showHUD(fnTrigger.lastError ?? "无法发送 Fn")
            return
        }
        showHUD("已发送 Fn，观察微信输入法", sticky: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.fnTrigger.release()
            self?.showHUD("Fn 已释放")
        }
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
        buttons.start()
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
        // A very fast second press while the previous IME session is draining
        // must release the old Fn before starting a new one.
        if fnTrigger.isHeld {
            fnTrigger.release()
            inputLock.unlock()
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

        voiceSessionActive = true
        isRecording = true
        activeVoiceMode = .wechatIME
        imeGeneration &+= 1
        _ = link.sendMicrophoneOpen()

        if settings.lockSystemInput {
            _ = inputLock.lock(to: virtualMic.deviceUID)
            defaultInputName = CoreAudioDeviceCatalog.defaultInputDeviceName()
        }
        virtualMic.beginSession()

        guard fnTrigger.press() else {
            virtualMic.stop()
            inputLock.unlock()
            voiceSessionActive = false
            isRecording = false
            activeVoiceMode = .appleSpeech
            showHUD(fnTrigger.lastError ?? "无法触发微信输入法")
            return
        }
        showHUD("正在听（微信输入法）…", sticky: true)
        onStatusChange?()
    }

    private func startAppleVoice() {
        voiceSessionActive = true
        isRecording = true
        activeVoiceMode = .appleSpeech
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
            showHUD("微信输入法识别中…", sticky: true)
            finishIMEWhenDrained()
        case .appleSpeech, .automatic:
            if speechState == .listening {
                speech.finish()
                showHUD("识别中…", sticky: true)
            } else {
                hud.hide()
            }
            activeVoiceMode = .appleSpeech
        }
        onStatusChange?()
    }

    private func finishIMEWhenDrained() {
        let token = imeGeneration
        let finish = { [weak self] in
            self?.finishIME(token: token)
        }
        imeReleaseWork?.cancel()
        let work = DispatchWorkItem(block: finish)
        imeReleaseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
        virtualMic.whenDrained(finish)
    }

    private func finishIME(token: UInt64) {
        guard token == imeGeneration, activeVoiceMode == .wechatIME else { return }
        imeReleaseWork?.cancel()
        imeReleaseWork = nil
        virtualMic.cancelDrain()
        fnTrigger.release()
        if settings.lockSystemInput { inputLock.unlock() }
        defaultInputName = CoreAudioDeviceCatalog.defaultInputDeviceName()
        activeVoiceMode = .appleSpeech
        showHUD("已交给微信输入法")
        onStatusChange?()
    }

    private func handleFinalText(_ text: String) {
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
        showHUD(message)
        lastError(message)
    }

    private func lastError(_ message: String) {
        Log.error("app error: \(message)")
    }

    private func showHUD(_ message: String, sticky: Bool = false) {
        guard settings.showHUD else { return }
        hud.show(message, sticky: sticky)
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
        } else {
            speech.append(samples)
        }
    }

    func remoteLinkDidStopAudio(_ link: RemoteLink) {
        endVoice()
    }

    func remoteLink(_ link: RemoteLink, didFail message: String) {
        if activeVoiceMode == .wechatIME {
            finishIME(token: imeGeneration)
        } else if voiceSessionActive {
            speech.finish()
        }
        lastError(message)
        onStatusChange?()
    }
}

extension AppModel: RemoteButtonsDelegate {
    func remoteButtons(_ buttons: RemoteButtons, didPress button: RemoteButton) {
        let binding = settings.binding(for: button)
        guard binding.kind != .none else { return }
        if !accessibilityGranted && (binding.kind == .preset || binding.kind == .shortcut) {
            if !warnedAccessibility {
                warnedAccessibility = true
                showHUD("请授权辅助功能以发送按键")
            }
            return
        }
        KeyInjector.perform(binding)
    }

    func remoteButtonsDidPressVoice(_ buttons: RemoteButtons) {
        beginVoice()
    }

    func remoteButtonsDidReleaseVoice(_ buttons: RemoteButtons) {
        endVoice()
    }

    func remoteButtons(_ buttons: RemoteButtons, didChange mode: RemoteButtons.Mode) {
        hidMode = mode
        if case .ready(seized: false, devices: let devices) = mode, devices > 0 {
            showHUD("未能独占遥控器：自定义按键已停用")
        }
        onStatusChange?()
    }

    func remoteButtons(_ buttons: RemoteButtons, didSeeUnknown usages: [UInt16]) {
        Log.debug("unknown HID usages: \(usages.map(String.init).joined(separator: ","))")
    }
}
