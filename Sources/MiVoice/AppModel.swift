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
    @Published var recordingButton: RemoteButton?

    var onStatusChange: (() -> Void)?

    private let link = RemoteLink()
    private let buttons = RemoteButtons()
    private let speech = SpeechEngine()
    private let hud = HUD()
    private var voiceSessionActive = false
    private var warnedAccessibility = false
    private var started = false

    init() {
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
        link.stop()
        buttons.stop()
        speech.cancel()
        hud.hide()
    }

    @objc private func applicationDidBecomeActive() {
        refreshPermissions()
        refreshDiagnostics()
    }

    @objc private func systemDidWake() {
        if !buttons.mode.isSeized {
            buttons.stop()
            buttons.start()
        }
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
        if case .ready = linkState {
            // continue
        } else {
            showHUD("遥控器未连接")
            return
        }

        voiceSessionActive = true
        isRecording = true
        _ = link.sendMicrophoneOpen()

        if speech.start(localeIdentifier: settings.localeIdentifier) {
            showHUD("正在听…", sticky: true)
        } else {
            voiceSessionActive = false
            isRecording = false
            link.sendMicrophoneClose()
        }
        onStatusChange?()
    }

    private func endVoice() {
        guard voiceSessionActive else { return }
        voiceSessionActive = false
        isRecording = false
        link.sendMicrophoneClose()
        if speechState == .listening {
            speech.finish()
            showHUD("识别中…", sticky: true)
        } else {
            hud.hide()
        }
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
            "语音识别：\(speechDiagnostics)",
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
        speech.append(samples)
    }

    func remoteLinkDidStopAudio(_ link: RemoteLink) {
        endVoice()
    }

    func remoteLink(_ link: RemoteLink, didFail message: String) {
        if voiceSessionActive {
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
