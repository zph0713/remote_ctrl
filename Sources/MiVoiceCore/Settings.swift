import Foundation

/// Physical buttons on the Xiaomi RC003. The voice key is handled separately
/// because it is hold-to-talk, not a normal mapping target.
public enum RemoteButton: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case power
    case up
    case left
    case ok
    case right
    case down
    case back
    case volumeUp = "volume_up"
    case home
    case volumeDown = "volume_down"
    case menu
    case tv

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .power: return "电源"
        case .up: return "方向上"
        case .left: return "方向左"
        case .ok: return "确定"
        case .right: return "方向右"
        case .down: return "方向下"
        case .back: return "返回"
        case .home: return "主页"
        case .menu: return "菜单"
        case .tv: return "TV"
        case .volumeUp: return "音量 +"
        case .volumeDown: return "音量 −"
        }
    }

    /// HID keyboard-page usages reported by the remote.
    public var hidUsage: UInt16 {
        switch self {
        case .power: return 0x66
        case .up: return 0x52
        case .left: return 0x50
        case .ok: return 0x28
        case .right: return 0x4F
        case .down: return 0x51
        case .back: return 0xF1
        case .volumeUp: return 0x80
        case .home: return 0x4A
        case .volumeDown: return 0x81
        case .menu: return 0x65
        case .tv: return 0x35
        }
    }

    public static let usageMap: [UInt16: RemoteButton] = Dictionary(
        uniqueKeysWithValues: allCases.map { ($0.hidUsage, $0) }
    )

    /// The voice key is F5 (0x3E) on RC003. Some firmware also reports 0x0C.
    public static let voiceUsages: Set<UInt16> = [0x3E, 0x0C]
}

/// Built-in actions that do not need a custom shortcut.
public enum PresetAction: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case returnKey
    case escape
    case deleteBackward
    case tab
    case space
    case arrowUp
    case arrowDown
    case arrowLeft
    case arrowRight
    case pageUp
    case pageDown
    case homeKey
    case endKey
    case appSwitcher
    case spotlight
    case showDesktop
    case missionControl
    case contextMenu
    case lockScreen
    case copy
    case paste
    case cut
    case selectAll
    case undo
    case save
    case find
    case volumeUp
    case volumeDown
    case mute
    case playPause
    case nextTrack
    case previousTrack

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .returnKey: return "回车"
        case .escape: return "Esc"
        case .deleteBackward: return "删除（退格）"
        case .tab: return "Tab"
        case .space: return "空格"
        case .arrowUp: return "上箭头"
        case .arrowDown: return "下箭头"
        case .arrowLeft: return "左箭头"
        case .arrowRight: return "右箭头"
        case .pageUp: return "Page Up"
        case .pageDown: return "Page Down"
        case .homeKey: return "Home"
        case .endKey: return "End"
        case .appSwitcher: return "切换应用（⌘Tab）"
        case .spotlight: return "聚焦搜索（⌘Space）"
        case .showDesktop: return "显示桌面（Fn-F11）"
        case .missionControl: return "调度中心（⌃↑）"
        case .contextMenu: return "上下文菜单"
        case .lockScreen: return "锁定屏幕（⌃⌘Q）"
        case .copy: return "复制（⌘C）"
        case .paste: return "粘贴（⌘V）"
        case .cut: return "剪切（⌘X）"
        case .selectAll: return "全选（⌘A）"
        case .undo: return "撤销（⌘Z）"
        case .save: return "保存（⌘S）"
        case .find: return "查找（⌘F）"
        case .volumeUp: return "音量 +"
        case .volumeDown: return "音量 −"
        case .mute: return "静音"
        case .playPause: return "播放 / 暂停"
        case .nextTrack: return "下一首"
        case .previousTrack: return "上一首"
        }
    }
}

public enum VoiceMode: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case appleSpeech
    case wechatIME
    case automatic

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .appleSpeech: return "Apple 离线识别（直接粘贴）"
        case .wechatIME: return "微信输入法（虚拟麦克风）"
        case .automatic: return "自动（有虚拟麦克风就用微信输入法）"
        }
    }

    public var detail: String {
        switch self {
        case .appleSpeech: return "音频只在本机识别，文字由 MiVoice 粘贴"
        case .wechatIME: return "音频送进虚拟麦克风，由微信输入法识别并上屏"
        case .automatic: return "找到 BlackHole / MiRemoteV 时优先微信输入法"
        }
    }
}

public struct ButtonBinding: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Hashable, Sendable {
        case none
        case preset
        case shortcut
        case openApp

        public var title: String {
            switch self {
            case .none: return "无动作"
            case .preset: return "预设动作"
            case .shortcut: return "自定义快捷键"
            case .openApp: return "打开应用"
            }
        }
    }

    public var kind: Kind
    public var preset: PresetAction?
    public var keyCode: UInt16?
    /// CGEventFlags raw value. Kept as UInt so MiVoiceCore stays Foundation-only.
    public var flags: UInt?
    public var appPath: String?

    public init(
        kind: Kind = .none,
        preset: PresetAction? = nil,
        keyCode: UInt16? = nil,
        flags: UInt? = nil,
        appPath: String? = nil
    ) {
        self.kind = kind
        self.preset = preset
        self.keyCode = keyCode
        self.flags = flags
        self.appPath = appPath
    }

    public static let none = ButtonBinding()

    public static func presetAction(_ action: PresetAction) -> ButtonBinding {
        ButtonBinding(kind: .preset, preset: action)
    }

    public static func shortcut(keyCode: UInt16, flags: UInt) -> ButtonBinding {
        ButtonBinding(kind: .shortcut, keyCode: keyCode, flags: flags)
    }

    public static func openApp(path: String) -> ButtonBinding {
        ButtonBinding(kind: .openApp, appPath: path)
    }

    private enum CodingKeys: String, CodingKey {
        case kind, preset, keyCode, flags, appPath
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let rawKind = try container.decodeIfPresent(String.self, forKey: .kind) {
            kind = Kind(rawValue: rawKind) ?? .none
        } else {
            kind = .none
        }
        if let rawPreset = try container.decodeIfPresent(String.self, forKey: .preset) {
            preset = PresetAction(rawValue: rawPreset)
        } else {
            preset = nil
        }
        keyCode = try container.decodeIfPresent(UInt16.self, forKey: .keyCode)
        flags = try container.decodeIfPresent(UInt.self, forKey: .flags)
        appPath = try container.decodeIfPresent(String.self, forKey: .appPath)
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var localeIdentifier: String
    public var bindings: [String: ButtonBinding]
    public var launchAtLogin: Bool
    public var showHUD: Bool
    public var restoreClipboard: Bool
    public var voiceMode: VoiceMode
    public var virtualDeviceUID: String
    public var lockSystemInput: Bool

    public init(
        localeIdentifier: String = "zh-CN",
        bindings: [String: ButtonBinding] = AppSettings.defaultBindings,
        launchAtLogin: Bool = false,
        showHUD: Bool = true,
        restoreClipboard: Bool = true,
        voiceMode: VoiceMode = .appleSpeech,
        virtualDeviceUID: String = "",
        lockSystemInput: Bool = true
    ) {
        self.localeIdentifier = localeIdentifier
        self.bindings = bindings
        self.launchAtLogin = launchAtLogin
        self.showHUD = showHUD
        self.restoreClipboard = restoreClipboard
        self.voiceMode = voiceMode
        self.virtualDeviceUID = virtualDeviceUID
        self.lockSystemInput = lockSystemInput
    }

    public func binding(for button: RemoteButton) -> ButtonBinding {
        bindings[button.rawValue] ?? .none
    }

    public mutating func setBinding(_ binding: ButtonBinding, for button: RemoteButton) {
        bindings[button.rawValue] = binding
    }

    public static var defaultBindings: [String: ButtonBinding] {
        var result: [String: ButtonBinding] = [:]
        result[RemoteButton.up.rawValue] = .presetAction(.arrowUp)
        result[RemoteButton.down.rawValue] = .presetAction(.arrowDown)
        result[RemoteButton.left.rawValue] = .presetAction(.arrowLeft)
        result[RemoteButton.right.rawValue] = .presetAction(.arrowRight)
        result[RemoteButton.ok.rawValue] = .presetAction(.returnKey)
        result[RemoteButton.back.rawValue] = .presetAction(.deleteBackward)
        result[RemoteButton.home.rawValue] = .presetAction(.showDesktop)
        result[RemoteButton.menu.rawValue] = .presetAction(.contextMenu)
        result[RemoteButton.tv.rawValue] = .presetAction(.appSwitcher)
        result[RemoteButton.power.rawValue] = ButtonBinding(kind: .none)
        result[RemoteButton.volumeUp.rawValue] = .presetAction(.volumeUp)
        result[RemoteButton.volumeDown.rawValue] = .presetAction(.volumeDown)
        return result
    }

    private enum CodingKeys: String, CodingKey {
        case localeIdentifier, bindings, launchAtLogin, showHUD, restoreClipboard
        case voiceMode, virtualDeviceUID, lockSystemInput
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        localeIdentifier = try container.decodeIfPresent(String.self, forKey: .localeIdentifier) ?? "zh-CN"
        let stored = try container.decodeIfPresent([String: ButtonBinding].self, forKey: .bindings) ?? [:]
        var merged = AppSettings.defaultBindings
        for (key, value) in stored {
            merged[key] = value
        }
        bindings = merged
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        showHUD = try container.decodeIfPresent(Bool.self, forKey: .showHUD) ?? true
        restoreClipboard = try container.decodeIfPresent(Bool.self, forKey: .restoreClipboard) ?? true
        if let rawVoiceMode = try container.decodeIfPresent(String.self, forKey: .voiceMode) {
            voiceMode = VoiceMode(rawValue: rawVoiceMode) ?? .appleSpeech
        } else {
            voiceMode = .appleSpeech
        }
        virtualDeviceUID = try container.decodeIfPresent(String.self, forKey: .virtualDeviceUID) ?? ""
        lockSystemInput = try container.decodeIfPresent(Bool.self, forKey: .lockSystemInput) ?? true
    }
}
