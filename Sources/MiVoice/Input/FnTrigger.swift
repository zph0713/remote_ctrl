import ApplicationServices
import CoreGraphics
import Foundation

/// Sends a synthetic Fn (Globe) hold. WeChat Input Method 2.0+ uses hold-Fn
/// for voice input; because MiVoice seizes the remote's HID interface, the
/// physical voice key never reaches the input method, so we reproduce it.
final class FnTrigger {
    private let source = CGEventSource(stateID: .privateState)
    private(set) var isHeld = false
    private(set) var lastError: String?

    @discardableResult
    func press() -> Bool {
        guard AXIsProcessTrusted() else {
            lastError = "需要辅助功能权限才能触发微信输入法"
            return false
        }
        guard !isHeld else { return true }
        guard let event = CGEvent(
            keyboardEventSource: source,
            virtualKey: 63,
            keyDown: true
        ) else {
            lastError = "无法创建 Fn 事件"
            return false
        }
        event.type = .flagsChanged
        var flags = CGEventSource.flagsState(.hidSystemState)
        flags.remove(.maskSecondaryFn)
        flags.insert(.maskSecondaryFn)
        event.flags = flags
        event.post(tap: .cghidEventTap)
        isHeld = true
        lastError = nil
        return true
    }

    func release() {
        guard isHeld else { return }
        if let event = CGEvent(
            keyboardEventSource: source,
            virtualKey: 63,
            keyDown: false
        ) {
            event.type = .flagsChanged
            var flags = CGEventSource.flagsState(.hidSystemState)
            flags.remove(.maskSecondaryFn)
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
        isHeld = false
    }
}
