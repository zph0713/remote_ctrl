import Foundation
import IOKit.hid
import MiVoiceCore

protocol RemoteButtonsDelegate: AnyObject {
    func remoteButtons(_ buttons: RemoteButtons, didPress button: RemoteButton)
    func remoteButtonsDidPressVoice(_ buttons: RemoteButtons)
    func remoteButtonsDidReleaseVoice(_ buttons: RemoteButtons)
    func remoteButtons(_ buttons: RemoteButtons, didChange mode: RemoteButtons.Mode)
    func remoteButtons(_ buttons: RemoteButtons, didSeeUnknown usages: [UInt16])
}

private let remoteButtonsDeviceMatched: IOHIDDeviceCallback = { context, _, _, _ in
    guard let context else { return }
    Unmanaged<RemoteButtons>.fromOpaque(context).takeUnretainedValue().deviceAdded()
}

private let remoteButtonsDeviceRemoved: IOHIDDeviceCallback = { context, _, _, _ in
    guard let context else { return }
    Unmanaged<RemoteButtons>.fromOpaque(context).takeUnretainedValue().deviceRemoved()
}

private let remoteButtonsReport: IOHIDReportCallback = {
    context, _, _, _, reportID, report, reportLength in
    guard let context, reportLength > 0 else { return }
    let bytes = [UInt8](UnsafeBufferPointer(start: report, count: reportLength))
    Unmanaged<RemoteButtons>.fromOpaque(context).takeUnretainedValue()
        .received(reportID: reportID, bytes: bytes)
}

/// Seizes the RC003 keyboard interface so its native key events never reach
/// macOS. If the seize is refused, the app keeps working for voice input but
/// disables custom button actions to avoid double-triggering system shortcuts.
final class RemoteButtons {
    enum Mode: Equatable {
        case off
        case starting
        case ready(seized: Bool, devices: Int)
        case failed(String)

        var text: String {
            switch self {
            case .off: return "未启用"
            case .starting: return "正在打开按键通道…"
            case .ready(let seized, let devices):
                if devices == 0 { return "等待遥控器按键…" }
                return seized ? "已独占（自定义按键可用）" : "仅监听（自定义按键停用）"
            case .failed(let message): return message
            }
        }

        var isSeized: Bool {
            if case .ready(let seized, _) = self { return seized }
            return false
        }
    }

    weak var delegate: RemoteButtonsDelegate?

    private(set) var mode: Mode = .off {
        didSet {
            if oldValue != mode {
                delegate?.remoteButtons(self, didChange: mode)
            }
        }
    }

    private var manager: IOHIDManager?
    private var deviceCount = 0
    private var seized = false
    private var activeUsages = Set<UInt16>()
    private var lastReport: (usages: Set<UInt16>, time: TimeInterval)?

    func start() {
        guard manager == nil else { return }
        guard Permissions.inputMonitoring else {
            mode = .failed("未授予输入监控，自定义按键不可用")
            return
        }

        mode = .starting
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: 0x2717,
            kIOHIDProductIDKey as String: 0x32B8,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, remoteButtonsDeviceMatched, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, remoteButtonsDeviceRemoved, context)
        IOHIDManagerRegisterInputReportCallback(manager, remoteButtonsReport, context)
        IOHIDManagerScheduleWithRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.commonModes.rawValue
        )

        var result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        var didSeize = true
        if result != kIOReturnSuccess {
            Log.info("HID seize refused, falling back to monitor-only")
            result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            didSeize = false
        }
        guard result == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(
                manager,
                CFRunLoopGetMain(),
                CFRunLoopMode.commonModes.rawValue
            )
            mode = .failed("无法打开遥控器按键通道（错误 \(result)）")
            return
        }

        self.manager = manager
        self.seized = didSeize
        mode = .ready(seized: didSeize, devices: deviceCount)
        Log.info("HID started seized=\(didSeize)")
    }

    func stop() {
        if let manager {
            IOHIDManagerUnscheduleFromRunLoop(
                manager,
                CFRunLoopGetMain(),
                CFRunLoopMode.commonModes.rawValue
            )
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil
        deviceCount = 0
        seized = false
        activeUsages.removeAll()
        lastReport = nil
        mode = .off
    }

    fileprivate func deviceAdded() {
        deviceCount += 1
        updateReadyMode()
    }

    fileprivate func deviceRemoved() {
        deviceCount = max(0, deviceCount - 1)
        activeUsages.removeAll()
        updateReadyMode()
    }

    fileprivate func received(reportID: UInt32, bytes: [UInt8]) {
        guard let usages = HIDReportParser.usages(reportID: reportID, bytes: bytes) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let lastReport, lastReport.usages == usages, now - lastReport.time < 0.03 {
            return
        }
        lastReport = (usages, now)
        process(usages)
    }

    private func process(_ usages: Set<UInt16>) {
        let pressed = usages.subtracting(activeUsages)
        let released = activeUsages.subtracting(usages)
        activeUsages = usages

        if !pressed.intersection(RemoteButton.voiceUsages).isEmpty {
            delegate?.remoteButtonsDidPressVoice(self)
        }
        if !released.intersection(RemoteButton.voiceUsages).isEmpty {
            delegate?.remoteButtonsDidReleaseVoice(self)
        }

        guard seized else {
            return
        }

        var unknown: [UInt16] = []
        for usage in pressed.sorted() {
            if RemoteButton.voiceUsages.contains(usage) { continue }
            if let button = RemoteButton.usageMap[usage] {
                delegate?.remoteButtons(self, didPress: button)
            } else {
                unknown.append(usage)
            }
        }
        if !unknown.isEmpty {
            delegate?.remoteButtons(self, didSeeUnknown: unknown)
        }
    }

    private func updateReadyMode() {
        guard manager != nil else { return }
        mode = .ready(seized: seized, devices: deviceCount)
    }
}
