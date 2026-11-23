import AppKit
import ApplicationServices
import IOKit.hid

enum Permissions {
    static var accessibility: Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system Accessibility prompt and opens the matching pane.
    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static var inputMonitoring: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == IOHIDAccessType(rawValue: 0)
    }

    /// Shows the Input Monitoring prompt. macOS may require an app restart
    /// before new access is visible to an already running process.
    static func requestInputMonitoring() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    static func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}
