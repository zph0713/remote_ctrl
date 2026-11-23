import CoreAudio
import Foundation

/// Temporarily makes the virtual microphone the system default input so the
/// input method records from it, then restores the previous input.
final class SystemInputLock {
    private var targetUID: String?
    private var previousUID: String?
    private(set) var lastError: String?

    var isLocked: Bool { targetUID != nil }

    @discardableResult
    func lock(to uid: String) -> Bool {
        guard !uid.isEmpty else { return false }
        if targetUID == uid { return true }
        if targetUID == nil {
            previousUID = CoreAudioDeviceCatalog.defaultInputDeviceUID()
        }
        guard CoreAudioDeviceCatalog.setDefaultInputDevice(uid: uid),
              CoreAudioDeviceCatalog.defaultInputDeviceUID() == uid else {
            lastError = "无法切换系统输入设备"
            return false
        }
        targetUID = uid
        lastError = nil
        return true
    }

    func unlock() {
        defer {
            targetUID = nil
            previousUID = nil
        }
        guard let target = targetUID else { return }
        guard CoreAudioDeviceCatalog.defaultInputDeviceUID() == target else { return }
        if let previous = previousUID, !previous.isEmpty {
            _ = CoreAudioDeviceCatalog.setDefaultInputDevice(uid: previous)
        }
    }
}
