import AppKit
import CoreGraphics
import MiVoiceCore

enum InsertResult {
    case pasted
    case copied
    case failed
}

enum KeyInjector {
    // MARK: - Keyboard

    static func postKey(_ code: CGKeyCode, flags: CGEventFlags = []) {
        guard AXIsProcessTrusted() else { return }
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
        down?.flags = flags
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
        up?.flags = flags
        up?.post(tap: .cghidEventTap)
    }

    static func postKeySlowRelease(_ code: CGKeyCode, flags: CGEventFlags = []) {
        guard AXIsProcessTrusted() else { return }
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
        down?.flags = flags
        down?.post(tap: .cghidEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
            up?.flags = flags
            up?.post(tap: .cghidEventTap)
        }
    }

    // MARK: - System keys (volume / media)

    private enum SystemKey: Int32 {
        case soundUp = 0
        case soundDown = 1
        case mute = 7
        case playPause = 16
        case nextTrack = 17
        case previousTrack = 18
    }

    private static func postSystemKey(_ key: SystemKey, down: Bool) {
        guard AXIsProcessTrusted() else { return }
        let data1 = (Int(key.rawValue) << 16) | (down ? 0xA : 0xB)
        guard let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: data1,
            data2: -1
        ) else { return }
        event.cgEvent?.post(tap: .cghidEventTap)
    }

    private static func tapSystemKey(_ key: SystemKey) {
        postSystemKey(key, down: true)
        postSystemKey(key, down: false)
    }

    // MARK: - Presets

    static func perform(_ preset: PresetAction) {
        switch preset {
        case .returnKey: postKey(36)
        case .escape: postKey(53)
        case .deleteBackward: postKey(51)
        case .tab: postKey(48)
        case .space: postKey(49)
        case .arrowUp: postKey(126)
        case .arrowDown: postKey(125)
        case .arrowLeft: postKey(123)
        case .arrowRight: postKey(124)
        case .pageUp: postKey(116)
        case .pageDown: postKey(121)
        case .homeKey: postKey(115)
        case .endKey: postKey(119)
        case .appSwitcher: postKeySlowRelease(48, flags: .maskCommand)
        case .spotlight: postKey(49, flags: .maskCommand)
        case .showDesktop: postKey(103, flags: .maskSecondaryFn)
        case .missionControl: postKey(126, flags: .maskControl)
        case .contextMenu: postKey(110)
        case .lockScreen: postKey(12, flags: [.maskControl, .maskCommand])
        case .copy: postKey(8, flags: .maskCommand)
        case .paste: postKey(9, flags: .maskCommand)
        case .cut: postKey(7, flags: .maskCommand)
        case .selectAll: postKey(0, flags: .maskCommand)
        case .undo: postKey(6, flags: .maskCommand)
        case .save: postKey(1, flags: .maskCommand)
        case .find: postKey(3, flags: .maskCommand)
        case .volumeUp: tapSystemKey(.soundUp)
        case .volumeDown: tapSystemKey(.soundDown)
        case .mute: tapSystemKey(.mute)
        case .playPause: tapSystemKey(.playPause)
        case .nextTrack: tapSystemKey(.nextTrack)
        case .previousTrack: tapSystemKey(.previousTrack)
        }
    }

    static func perform(_ binding: ButtonBinding) {
        switch binding.kind {
        case .none:
            return
        case .preset:
            if let preset = binding.preset {
                perform(preset)
            }
        case .shortcut:
            guard let code = binding.keyCode else { return }
            let flags = CGEventFlags(rawValue: UInt64(binding.flags ?? 0))
            postKey(CGKeyCode(code), flags: flags)
        case .openApp:
            guard let path = binding.appPath, !path.isEmpty else { return }
            openApplication(at: path)
        }
    }

    static func openApplication(at path: String) {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            Log.error("app path missing")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error {
                Log.error("open app failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Text insertion

    /// Pastes `text` into the frontmost app. The previous clipboard is restored
    /// unless the user copies something else in the meantime.
    static func insertText(_ text: String, restoreClipboard: Bool) -> InsertResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failed }

        let pasteboard = NSPasteboard.general
        let savedItems = snapshot(pasteboard)

        guard AXIsProcessTrusted() else {
            copyToClipboard(trimmed)
            return .copied
        }

        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier {
            copyToClipboard(trimmed)
            return .copied
        }

        pasteboard.clearContents()
        guard pasteboard.setString(trimmed, forType: .string) else {
            return .failed
        }
        let expectedChangeCount = pasteboard.changeCount

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            postKey(9, flags: .maskCommand)
        }

        if restoreClipboard {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                guard pasteboard.changeCount == expectedChangeCount else { return }
                pasteboard.clearContents()
                if let savedItems {
                    pasteboard.writeObjects(savedItems.map { $0 as NSPasteboardWriting })
                }
            }
        }
        return .pasted
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> [NSPasteboardItem]? {
        guard let items = pasteboard.pasteboardItems else { return nil }
        return items.map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    static func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
