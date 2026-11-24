import Foundation
import IOKit.hid
import MiVoiceCore

protocol RemoteButtonsDelegate: AnyObject {
    func remoteButtons(_ buttons: RemoteButtons, didTrigger button: RemoteButton, trigger: ButtonTrigger)
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
        case ready(seized: Bool, actions: Bool, devices: Int)
        case failed(String)

        var text: String {
            switch self {
            case .off: return "未启用"
            case .starting: return "正在打开按键通道…"
            case .ready(let seized, let actions, let devices):
                if devices == 0 { return "等待遥控器按键…" }
                if seized { return "已独占（自定义按键可用）" }
                if actions { return "Fn 映射模式（自定义按键可用）" }
                return "仅监听（自定义按键停用）"
            case .failed(let message): return message
            }
        }

        var isSeized: Bool {
            if case .ready(let seized, _, _) = self { return seized }
            return false
        }

        var actionsEnabled: Bool {
            if case .ready(_, let actions, _) = self { return actions }
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
    private var actionsEnabled = false
    private var activeUsages = Set<UInt16>()
    private var lastReport: (usages: Set<UInt16>, time: TimeInterval)?
    private var gestures = ButtonGestureRecognizer()
    private var doubleTimers: [RemoteButton: DispatchWorkItem] = [:]
    private var longTimers: [RemoteButton: DispatchWorkItem] = [:]
    /// Returns which gestures are configured for a button. A button with no
    /// double/long action fires its single action immediately instead of
    /// waiting for a timeout.
    var gestureConfiguration: ((RemoteButton) -> (double: Bool, long: Bool))?
    var doubleClickInterval: TimeInterval = 0.30
    var longPressInterval: TimeInterval = 0.55

    var isSeized: Bool { seized }
    var isActionsEnabled: Bool { actionsEnabled }

    func start(seize: Bool = true, allowActions: Bool = false) {
        Log.info("HID.start request seize=\(seize) allowActions=\(allowActions)")
        guard manager == nil else { return }
        guard Permissions.inputMonitoring else {
            mode = .failed("未授予输入监控，自定义按键不可用")
            Log.error("HID.start result=no_input_monitoring")
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

        var result: IOReturn
        var didSeize = false
        if seize {
            result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
            didSeize = result == kIOReturnSuccess
            if result != kIOReturnSuccess {
                Log.info("HID seize refused, falling back to monitor-only")
                result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            }
        } else {
            result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        guard result == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(
                manager,
                CFRunLoopGetMain(),
                CFRunLoopMode.commonModes.rawValue
            )
            mode = .failed("无法打开遥控器按键通道（错误 \(result)）")
            Log.error("HID.start result=failed code=\(result)")
            return
        }

        self.manager = manager
        self.seized = didSeize
        self.actionsEnabled = didSeize || allowActions
        mode = .ready(seized: didSeize, actions: self.actionsEnabled, devices: deviceCount)
        Log.info("HID started seized=\(didSeize) actions=\(self.actionsEnabled)")
    }

    func stop() {
        Log.info("HID.stop seized=\(seized) actions=\(actionsEnabled) devices=\(deviceCount)")
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
        actionsEnabled = false
        activeUsages.removeAll()
        lastReport = nil
        cancelGestureTimers()
        gestures.reset()
        mode = .off
    }

    fileprivate func deviceAdded() {
        deviceCount += 1
        Log.info("HID.deviceAdded count=\(deviceCount)")
        updateReadyMode()
    }

    fileprivate func deviceRemoved() {
        deviceCount = max(0, deviceCount - 1)
        Log.info("HID.deviceRemoved count=\(deviceCount)")
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

        guard actionsEnabled else {
            return
        }

        var unknown: [UInt16] = []
        for usage in pressed.sorted() {
            if RemoteButton.voiceUsages.contains(usage) { continue }
            if let button = RemoteButton.usageMap[usage] {
                handleGesture(.press, button: button)
            } else {
                unknown.append(usage)
            }
        }
        for usage in released.sorted() {
            if RemoteButton.voiceUsages.contains(usage) { continue }
            if let button = RemoteButton.usageMap[usage] {
                handleGesture(.release, button: button)
            }
        }
        if !unknown.isEmpty {
            delegate?.remoteButtons(self, didSeeUnknown: unknown)
        }
    }

    private func handleGesture(_ phase: RemoteButtonPhase, button: RemoteButton) {
        let options = gestureConfiguration?(button) ?? (double: false, long: false)
        let commands = gestures.handle(
            phase,
            button: button,
            recognizesDoubleClick: options.double,
            recognizesLongPress: options.long
        )
        apply(commands)
    }

    private func apply(_ commands: [ButtonGestureRecognizer.Command]) {
        for command in commands {
            switch command {
            case .scheduleDoubleClickTimeout(let button):
                doubleTimers[button]?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.doubleTimers[button] = nil
                    self.apply(self.gestures.doubleClickTimedOut(button))
                }
                doubleTimers[button] = work
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + doubleClickInterval,
                    execute: work
                )
            case .cancelDoubleClickTimeout(let button):
                doubleTimers[button]?.cancel()
                doubleTimers[button] = nil
            case .scheduleLongPressTimeout(let button):
                longTimers[button]?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.longTimers[button] = nil
                    self.apply(self.gestures.longPressTimedOut(button))
                }
                longTimers[button] = work
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + longPressInterval,
                    execute: work
                )
            case .cancelLongPressTimeout(let button):
                longTimers[button]?.cancel()
                longTimers[button] = nil
            case .trigger(let button, let trigger):
                delegate?.remoteButtons(self, didTrigger: button, trigger: trigger)
            }
        }
    }

    private func cancelGestureTimers() {
        for work in doubleTimers.values { work.cancel() }
        for work in longTimers.values { work.cancel() }
        doubleTimers.removeAll()
        longTimers.removeAll()
    }

    private func updateReadyMode() {
        guard manager != nil else { return }
        mode = .ready(seized: seized, actions: actionsEnabled, devices: deviceCount)
    }
}
