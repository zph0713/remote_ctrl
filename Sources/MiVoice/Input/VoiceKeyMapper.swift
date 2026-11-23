// SPDX-License-Identifier: GPL-3.0-only
// HID voice-key mapping adapted from ericyangpan/mi-remote-helper
// (GPL-3.0-only). See NOTICE.
import Foundation
import IOKit.hid
import MiVoiceCore

struct HIDKeyMapping: Equatable {
    static let sourceKey = "HIDKeyboardModifierMappingSrc"
    static let destinationKey = "HIDKeyboardModifierMappingDst"

    let source: UInt64
    let destination: UInt64

    var dictionary: [String: NSNumber] {
        [
            Self.sourceKey: NSNumber(value: source),
            Self.destinationKey: NSNumber(value: destination),
        ]
    }

    static func equivalent(_ lhs: [HIDKeyMapping], _ rhs: [HIDKeyMapping]) -> Bool {
        func ordered(_ values: [HIDKeyMapping]) -> [HIDKeyMapping] {
            values.sorted {
                $0.source == $1.source ? $0.destination < $1.destination : $0.source < $1.source
            }
        }
        return ordered(lhs) == ordered(rhs)
    }
}

/// Maps the RC003 voice key to the Apple Fn usage **at the HID service level**.
/// Unlike a synthetic CGEvent, the input method receives this exactly like the
/// physical Fn key. Ordinary remote buttons are mapped to 0 so they do not
/// double-trigger native system actions; MiVoice still reads the raw reports
/// and injects its own mappings.
final class VoiceKeyMapper {
    private struct Snapshot {
        let original: UInt64?
        var installed: UInt64
    }

    // Service clients depend on their event-system connection. Keep the owner
    // alive through every property read, mapping write and restoration.
    private var client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
    private let property = "UserKeyMapping" as CFString
    private var snapshots: [UInt64: [UInt64: Snapshot]] = [:]
    private(set) var error: String?

    static let voiceSource: UInt64 = 0x0000_0007_0000_003E
    /// Some firmware reports the voice key as 0x0C instead of F5.
    static let secondaryVoiceSource: UInt64 = 0x0000_0007_0000_000C
    static let fnDestination: UInt64 = 0x0000_00FF_0000_0003

    private static var desiredSources: Set<UInt64> {
        var result = Set(RemoteButton.allCases.map { keyboardUsage($0.hidUsage) })
        result.insert(voiceSource)
        result.insert(secondaryVoiceSource)
        return result
    }

    private static func keyboardUsage(_ usage: UInt16) -> UInt64 {
        0x0000_0007_0000_0000 | UInt64(usage)
    }

    private var desiredMappings: [UInt64: UInt64] {
        var result: [UInt64: UInt64] = [:]
        for button in RemoteButton.allCases {
            result[Self.keyboardUsage(button.hidUsage)] = 0
        }
        // Both known voice-key encodings become a real Fn press.
        result[Self.voiceSource] = Self.fnDestination
        result[Self.secondaryVoiceSource] = Self.fnDestination
        return result
    }

    var hasTargets: Bool { !targets().isEmpty }

    func isFnMappingApplied() -> Bool {
        targets().contains { service in
            read(service).contains {
                $0.source == Self.voiceSource && $0.destination == Self.fnDestination
            }
        }
    }

    @discardableResult
    func applyFnMapping() -> Bool {
        apply(destinations: desiredMappings)
    }

    /// Removes mappings for keys this app owns, even if a previous run crashed
    /// before it could restore them. Other keys and other tools' mappings are
    /// left untouched.
    @discardableResult
    func resetKnownMappings() -> Bool {
        var failed = false
        for service in targets() {
            let current = read(service)
            let desired = current.filter { !Self.desiredSources.contains($0.source) }
            if !update(current: current, desired: desired, service: service) {
                failed = true
            }
        }
        snapshots.removeAll()
        return !failed
    }

    private func apply(destinations: [UInt64: UInt64]) -> Bool {
        let services = targets()
        guard !services.isEmpty else {
            error = Permissions.inputMonitoring
                ? "未找到遥控器按键服务，请确认遥控器已连接"
                : "需要“输入监控”权限：系统设置 → 隐私与安全性 → 输入监控"
            return false
        }
        for service in services {
            guard let id = registryID(service) else {
                error = "无法识别遥控器按键服务"
                return false
            }
            let current = read(service)
            for (source, destination) in destinations {
                let existing = current.first { $0.source == source }?.destination
                if let saved = snapshots[id]?[source], existing != saved.installed {
                    error = "其它程序改动了遥控器按键映射，请先退出它们"
                    return false
                }
                if snapshots[id]?[source] == nil {
                    // If the key is already at our target value, it is a
                    // leftover from a previous run, not a user mapping.
                    snapshots[id, default: [:]][source] = Snapshot(
                        original: existing == destination ? nil : existing,
                        installed: destination
                    )
                }
            }
            let desired = current.filter { destinations[$0.source] == nil }
                + destinations.sorted { $0.key < $1.key }.map {
                    HIDKeyMapping(source: $0.key, destination: $0.value)
                }
            guard update(current: current, desired: desired, service: service) else {
                error = "无法写入 Fn 映射，请授予输入监控权限"
                _ = restore()
                return false
            }
            for (source, destination) in destinations {
                snapshots[id]?[source]?.installed = destination
            }
        }
        error = nil
        return true
    }

    @discardableResult
    func restore() -> Bool {
        let services = targets()
        var failed = false
        let present = Set(services.compactMap { registryID($0) })
        snapshots = snapshots.filter { present.contains($0.key) }
        for service in services {
            guard let id = registryID(service), let saved = snapshots[id] else { continue }
            let current = read(service)
            var desired = current
            for (source, snapshot) in saved {
                guard current.first(where: { $0.source == source })?.destination == snapshot.installed else {
                    continue
                }
                desired.removeAll { $0.source == source }
                if let original = snapshot.original {
                    desired.append(HIDKeyMapping(source: source, destination: original))
                }
            }
            if update(current: current, desired: desired, service: service) {
                snapshots.removeValue(forKey: id)
            } else {
                failed = true
            }
        }
        if failed {
            error = "无法恢复原来的按键映射，请断开并重新连接遥控器"
            client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        }
        return !failed
    }

    /// HID may reorder the mapping array or return false after accepting a
    /// property, so verify the resulting state instead of trusting the write.
    private func update(
        current: [HIDKeyMapping],
        desired: [HIDKeyMapping],
        service: IOHIDServiceClient
    ) -> Bool {
        if HIDKeyMapping.equivalent(current, desired) { return true }
        _ = write(desired, to: service)
        return HIDKeyMapping.equivalent(read(service), desired)
    }

    private func targets() -> [IOHIDServiceClient] {
        (IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? [])
            .filter {
                (IOHIDServiceClientCopyProperty($0, kIOHIDVendorIDKey as CFString) as? NSNumber)?.intValue == 0x2717
                    && (IOHIDServiceClientCopyProperty($0, kIOHIDProductIDKey as CFString) as? NSNumber)?.intValue == 0x32B8
            }
    }

    private func registryID(_ service: IOHIDServiceClient) -> UInt64? {
        (IOHIDServiceClientGetRegistryID(service) as? NSNumber)?.uint64Value
    }

    private func read(_ service: IOHIDServiceClient) -> [HIDKeyMapping] {
        let values = IOHIDServiceClientCopyProperty(service, property) as? [[String: NSNumber]] ?? []
        return values.compactMap {
            guard let source = $0[HIDKeyMapping.sourceKey],
                  let destination = $0[HIDKeyMapping.destinationKey] else { return nil }
            return HIDKeyMapping(
                source: source.uint64Value,
                destination: destination.uint64Value
            )
        }
    }

    private func write(_ values: [HIDKeyMapping], to service: IOHIDServiceClient) -> Bool {
        IOHIDServiceClientSetProperty(service, property, values.map(\.dictionary) as CFArray)
    }
}
