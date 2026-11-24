import AppKit
import CoreGraphics
import MiVoiceCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var eventMonitor: Any?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                statusCard
                voiceModeCard
                speechCard
                buttonsCard
                permissionsCard
                generalCard
                privacyCard
            }
            .padding(20)
        }
        .frame(minWidth: 720, minHeight: 720)
        .onAppear {
            model.refreshDiagnostics()
            model.refreshPermissions()
            model.startMacMicMonitor()
        }
        .onDisappear {
            removeMonitor()
            model.recordingButton = nil
            model.stopMacMicMonitor()
        }
        .onChange(of: model.recordingButton) { _, newValue in
            removeMonitor()
            guard let button = newValue else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
                if event.keyCode == 53 {
                    DispatchQueue.main.async {
                        model.recordingButton = nil
                    }
                    return nil
                }
                var flags = CGEventFlags()
                let modifiers = event.modifierFlags.intersection([
                    .command, .option, .control, .shift,
                ])
                if modifiers.contains(.command) { flags.insert(.maskCommand) }
                if modifiers.contains(.option) { flags.insert(.maskAlternate) }
                if modifiers.contains(.control) { flags.insert(.maskControl) }
                if modifiers.contains(.shift) { flags.insert(.maskShift) }
                model.setBinding(
                    .shortcut(keyCode: event.keyCode, flags: UInt(flags.rawValue)),
                    for: button,
                    trigger: model.recordingTrigger
                )
                DispatchQueue.main.async {
                    model.recordingButton = nil
                }
                return nil
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("MiVoice").font(.title2.weight(.semibold))
                Text("小米遥控器 → 本机语音输入")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var statusCard: some View {
        card("状态") {
            statusRow("遥控器", value: model.linkState.text) {
                Button("重新连接") { model.reconnectRemote() }
            }
            statusRow("按键通道", value: model.hidMode.text) {
                Button("重试") { model.retryButtons() }
            }
            statusRow("语音", value: speechStateText) {
                EmptyView()
            }
        }
    }

    private var voiceModeCard: some View {
        card("语音方式") {
            HStack {
                Text("识别方式").frame(width: 96, alignment: .leading)
                Picker("", selection: Binding(
                    get: { model.settings.voiceMode },
                    set: { model.setVoiceMode($0) }
                )) {
                    ForEach(VoiceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(width: 330)
                Spacer()
            }
            Text(model.settings.voiceMode.detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Text("虚拟麦克风").frame(width: 96, alignment: .leading)
                Picker("", selection: Binding(
                    get: { model.settings.virtualDeviceUID },
                    set: { model.setVirtualDevice($0) }
                )) {
                    if model.loopbackDevices.isEmpty {
                        Text("未找到（安装 BlackHole 2ch）").tag("")
                    }
                    ForEach(model.loopbackDevices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                .labelsHidden()
                .frame(width: 250)
                Button("刷新") {
                    model.refreshAudioDevices()
                    model.configureVirtualMic()
                }
                Spacer()
            }

            Toggle("语音时自动切换系统输入到虚拟麦克风", isOn: Binding(
                get: { model.settings.lockSystemInput },
                set: { model.setLockSystemInput($0) }
            ))
            Text("虚拟麦克风：\(model.virtualMicStatus)　系统输入：\(model.defaultInputName ?? "未知")")
                .font(.caption)
                .foregroundStyle(.secondary)

            levelRow(
                title: "遥控器麦克风",
                level: model.virtualMicLevel,
                detail: "BLE 音频 → 虚拟麦"
            )
            levelRow(
                title: "电脑麦克风",
                level: model.macMicLevel,
                detail: model.macMicStatus
            )
            HStack {
                Button("测试虚拟麦克风") { model.testVirtualMic() }
                Spacer()
            }
            Text("对着遥控器说话看第一条，对着电脑说话看第二条。电脑麦克风只在设置窗口打开时监听，不参与识别。")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack {
                Button("重新应用 Fn 映射") { model.reapplyVoiceMapping() }
                Button("打开声音设置") { model.openSoundSettings() }
                Spacer()
            }
            Text("Fn 映射：\(model.fnMappingStatus)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("微信输入法 2.0+ 默认按住 Fn 说话。选“微信输入法”后，MiVoice 在 HID 层把遥控器 F5 映射成 Fn（与物理 Fn 相同），并把 16 kHz 音频写进上面的虚拟麦克风。请先安装 BlackHole 2ch（或使用 SayAll 的 MiRemoteV 2ch）。")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Text("隐私提示：Apple 离线模式不上传音频；微信输入法会按它自己的隐私政策处理语音，MiVoice 本身不联网。")
                .font(.caption)
                .foregroundColor(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func levelRow(title: String, level: Float, detail: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule()
                        .fill(level > 0.01 ? Color.green : Color.secondary.opacity(0.35))
                        .frame(width: max(2, geo.size.width * CGFloat(min(1, level * 12))))
                }
            }
            .frame(height: 6)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 190, alignment: .trailing)
        }
    }

    private var speechCard: some View {
        card("语音输入") {
            HStack {
                Text("识别语言").frame(width: 96, alignment: .leading)
                Picker("", selection: Binding(
                    get: { model.settings.localeIdentifier },
                    set: { model.setLocale($0) }
                )) {
                    Text("中文（普通话）").tag("zh-CN")
                    Text("English (US)").tag("en-US")
                }
                .labelsHidden()
                .frame(width: 220)
                Spacer()
                Button("检查离线识别") { model.refreshDiagnostics() }
            }
            Text(model.speechDiagnostics)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("按住遥控器语音键说话，松开后文字会粘贴到当前应用。识别使用 macOS 离线模型，音频不离开本机。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var buttonsCard: some View {
        card("遥控器按键") {
            HStack {
                Text("按键").frame(width: 64, alignment: .leading)
                Text("手势").frame(width: 132, alignment: .leading)
                Text("动作与设置").frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text("每个按键可分别设置单击、双击、长按。双击窗口 300ms，长按 550ms；未配置双击/长按时会立即执行单击。")
                .font(.caption2)
                .foregroundStyle(.secondary)

            ForEach(RemoteButton.allCases) { button in
                ButtonBindingRow(model: model, button: button)
                if button != RemoteButton.allCases.last {
                    Divider()
                }
            }
        }
    }

    private var permissionsCard: some View {
        card("权限") {
            permissionRow(
                title: "蓝牙",
                granted: bluetoothGranted,
                detail: "连接遥控器；首次扫描时由系统询问",
                actionTitle: nil,
                action: nil
            )
            permissionRow(
                title: "语音识别",
                granted: model.speechAuthorization == .authorized,
                detail: "使用 macOS 离线语音模型",
                actionTitle: "请求",
                action: { model.requestSpeechAuthorization() }
            )
            permissionRow(
                title: "辅助功能",
                granted: model.accessibilityGranted,
                detail: "把识别文字粘贴到当前应用、发送自定义按键",
                actionTitle: "请求",
                action: { model.requestAccessibility() }
            )
            permissionRow(
                title: "输入监控",
                granted: model.inputMonitoringGranted,
                detail: "读取遥控器按键；授权后需要重启应用",
                actionTitle: "请求",
                action: { model.requestInputMonitoring() }
            )
            permissionRow(
                title: "麦克风",
                granted: model.macMicStatus.hasPrefix("监听中"),
                detail: "读取内建麦克风，仅用于电平对比；不参与识别",
                actionTitle: "请求",
                action: { model.requestMacMicAccess() }
            )
            HStack {
                Spacer()
                Button("退出并重新打开") { model.restartApplication() }
            }
        }
    }

    private var generalCard: some View {
        card("通用") {
            Toggle("登录时启动", isOn: Binding(
                get: { model.settings.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))
            Toggle("显示悬浮提示", isOn: Binding(
                get: { model.settings.showHUD },
                set: { model.setShowHUD($0) }
            ))
            Toggle("粘贴后恢复剪贴板", isOn: Binding(
                get: { model.settings.restoreClipboard },
                set: { model.setRestoreClipboard($0) }
            ))
            HStack {
                Button("复制诊断信息") { model.copyDiagnostics() }
                Button("导出诊断日志…") { model.exportDiagnostics() }
                Button("打开日志文件夹") { model.openLogFolder() }
                Spacer()
            }
        }
    }

    private var privacyCard: some View {
        card("隐私") {
            Text("""
            本应用没有任何联网代码，也不包含自动更新、账号、统计或云同步。\
            音频只在内存中解码，识别使用 macOS 离线模型；识别文字只粘贴到你当前使用的应用，\
            不写入磁盘、不保存历史，也不与其他用户交互。
            """)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func card<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private func statusRow<Accessory: View>(
        _ title: String,
        value: String,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(spacing: 10) {
            Text(title).frame(width: 96, alignment: .leading)
            Text(value).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            accessory()
        }
    }

    private func permissionRow(
        title: String,
        granted: Bool,
        detail: String,
        actionTitle: String?,
        action: (() -> Void)?
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(granted ? Color.green : Color.orange)
            Text(title).frame(width: 82, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(granted ? "已授权" : "未授权")
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let actionTitle, let action, !granted {
                Button(actionTitle, action: action)
            }
        }
    }

    private var bluetoothGranted: Bool {
        switch model.linkState {
        case .unauthorized: return false
        case .bluetoothOff: return false
        default: return true
        }
    }

    private var speechStateText: String {
        switch model.speechState {
        case .idle: return "就绪"
        case .listening: return "正在听…"
        case .finishing: return "识别中…"
        }
    }

    private func removeMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }
}

private struct ButtonBindingRow: View {
    @ObservedObject var model: AppModel
    let button: RemoteButton

    @State private var trigger: ButtonTrigger = .singleClick

    private var binding: ButtonBinding {
        model.settings.binding(for: button, trigger: trigger)
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(button.title)
                .frame(width: 64, alignment: .leading)

            Picker("", selection: $trigger) {
                ForEach(ButtonTrigger.allCases) { value in
                    Text(value.title).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 132)

            Picker("", selection: kindBinding) {
                ForEach(ButtonBinding.Kind.allCases, id: \.self) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .labelsHidden()
            .frame(width: 118)

            Group {
                switch binding.kind {
                case .none:
                    Text("—").foregroundStyle(.secondary)
                case .preset:
                    Picker("", selection: presetBinding) {
                        ForEach(PresetAction.allCases) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 260)
                case .shortcut:
                    HStack(spacing: 8) {
                        Text(shortcutLabel)
                            .font(.system(.body, design: .monospaced))
                            .frame(minWidth: 100, alignment: .leading)
                        Button(isRecording ? "按键…" : "录制") {
                            if isRecording {
                                model.recordingButton = nil
                            } else {
                                model.recordingButton = button
                                model.recordingTrigger = trigger
                            }
                        }
                        if isRecording {
                            Text("按 Esc 取消").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                case .text:
                    TextField("要输入的文字", text: textBinding)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                case .openApp:
                    HStack(spacing: 8) {
                        Text(appName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 240, alignment: .leading)
                        Button("选择…") { chooseApplication() }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 30)
    }

    private var isRecording: Bool {
        model.recordingButton == button && model.recordingTrigger == trigger
    }

    private var kindBinding: Binding<ButtonBinding.Kind> {
        Binding(
            get: { binding.kind },
            set: { kind in
                var next = binding
                next.kind = kind
                if kind == .preset, next.preset == nil {
                    next.preset = .returnKey
                }
                if kind == .shortcut, next.keyCode == nil {
                    next.keyCode = 36
                    next.flags = 0
                }
                if kind == .text, next.text == nil {
                    next.text = ""
                }
                model.setBinding(next, for: button, trigger: trigger)
            }
        )
    }

    private var presetBinding: Binding<PresetAction> {
        Binding(
            get: { binding.preset ?? .returnKey },
            set: { preset in
                var next = binding
                next.kind = .preset
                next.preset = preset
                model.setBinding(next, for: button, trigger: trigger)
            }
        )
    }

    private var textBinding: Binding<String> {
        Binding(
            get: { binding.text ?? "" },
            set: { value in
                var next = binding
                next.kind = .text
                next.text = value
                model.setBinding(next, for: button, trigger: trigger)
            }
        )
    }

    private var shortcutLabel: String {
        guard let code = binding.keyCode else { return "未设置" }
        return KeyNames.label(keyCode: code, flags: binding.flags ?? 0)
    }

    private var appName: String {
        guard let path = binding.appPath, !path.isEmpty else { return "未选择应用" }
        return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.setBinding(.openApp(path: url.path), for: button, trigger: trigger)
    }
}
