import Foundation

/// Xiaomi RC003 (Bluetooth Remote 2 Pro) voice transport.
///
/// Protocol constants and the ADPCM codec are adapted from
/// HD838A/remote-mic-app (GPL-3.0-only). See NOTICE at the repository root.
public enum ATVVProtocol {
    public static let serviceUUID = "AB5E0001-5A21-4F05-BC7D-AF01F617B664"
    public static let transmitUUID = "AB5E0002-5A21-4F05-BC7D-AF01F617B664"
    public static let audioUUID = "AB5E0003-5A21-4F05-BC7D-AF01F617B664"
    public static let controlUUID = "AB5E0004-5A21-4F05-BC7D-AF01F617B664"

    /// ATVV v1.0 "get capabilities".
    public static let getCapabilitiesV10 = Data([0x0A, 0x01, 0x00, 0x00, 0x03, 0x03])

    public static func supportsAudio(sampleRate: Double) -> Bool {
        sampleRate == 16_000
    }

    public static func microphoneOpen(version: UInt16, codec: UInt8) -> Data {
        if version >= 0x0100 {
            return Data([0x0C, 0x00])
        }
        return Data([0x0C, 0x00, codec])
    }

    public static func microphoneClose(version: UInt16, sessionID: UInt8) -> Data {
        if version >= 0x0100 {
            return Data([0x0D, sessionID])
        }
        return Data([0x0D])
    }
}

public struct ATVVCapabilities: Equatable, Sendable {
    public let version: UInt16
    public let codecs: UInt8
    public let interaction: UInt8
    public let frameSize: Int
    public let selectedCodec: UInt8
    public let sampleRate: Double

    public init(
        version: UInt16,
        codecs: UInt8,
        interaction: UInt8,
        frameSize: Int,
        selectedCodec: UInt8,
        sampleRate: Double
    ) {
        self.version = version
        self.codecs = codecs
        self.interaction = interaction
        self.frameSize = frameSize
        self.selectedCodec = selectedCodec
        self.sampleRate = sampleRate
    }

    /// Parses a `0x0B` capabilities notification.
    public static func parse(_ data: Data) -> ATVVCapabilities? {
        let bytes = Array(data)
        guard bytes.count >= 7, bytes[0] == 0x0B else { return nil }

        let version = UInt16(bytes[1]) << 8 | UInt16(bytes[2])
        var codecs: UInt8
        var interaction: UInt8

        if version >= 0x0100 {
            codecs = bytes[3]
            interaction = bytes[4]
            // Some firmware mirrors the codec byte in `interaction`.
            if codecs == 0, bytes.count >= 9, bytes[4] & 0x03 != 0 {
                codecs = bytes[4]
                interaction = 0x03
            }
        } else {
            guard bytes.count >= 9 else { return nil }
            codecs = bytes[4]
            interaction = 0
        }

        let frameSize = Int(bytes[5]) << 8 | Int(bytes[6])
        let selectedCodec: UInt8 = codecs & 0x02 != 0 ? 0x02 : 0x01
        return ATVVCapabilities(
            version: version,
            codecs: codecs,
            interaction: interaction,
            frameSize: frameSize == 0 ? 120 : frameSize,
            selectedCodec: selectedCodec,
            sampleRate: selectedCodec == 0x02 ? 16_000 : 8_000
        )
    }
}

/// IMA/DVI ADPCM decoder used by the RC003 microphone stream.
public final class IMAADPCMDecoder {
    private static let stepTable: [Int] = [
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31,
        34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130,
        143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449,
        494, 544, 598, 658, 724, 796, 876, 963, 1060, 1166, 1282, 1411,
        1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026,
        4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442,
        11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623,
        27086, 29794, 32767,
    ]
    private static let indexTable = [-1, -1, -1, -1, 2, 4, 6, 8]

    public private(set) var predictor = 0
    public private(set) var stepIndex = 0
    /// RC003 encodes high-nibble-first. Kept configurable for other firmwares.
    public var lowNibbleFirst = false

    public init() {}

    public func reset(predictor: Int = 0, stepIndex: Int = 0) {
        self.predictor = min(32_767, max(-32_768, predictor))
        self.stepIndex = min(88, max(0, stepIndex))
    }

    public func decode(_ data: Data) -> [Int16] {
        var samples: [Int16] = []
        samples.reserveCapacity(data.count * 2)
        for byte in data {
            if lowNibbleFirst {
                samples.append(decodeNibble(Int(byte & 0x0F)))
                samples.append(decodeNibble(Int(byte >> 4)))
            } else {
                samples.append(decodeNibble(Int(byte >> 4)))
                samples.append(decodeNibble(Int(byte & 0x0F)))
            }
        }
        return samples
    }

    private func decodeNibble(_ nibble: Int) -> Int16 {
        let step = Self.stepTable[stepIndex]
        var difference = step >> 3
        if nibble & 1 != 0 { difference += step >> 2 }
        if nibble & 2 != 0 { difference += step >> 1 }
        if nibble & 4 != 0 { difference += step }

        predictor += nibble & 8 != 0 ? -difference : difference
        predictor = min(32_767, max(-32_768, predictor))
        stepIndex += Self.indexTable[nibble & 7]
        stepIndex = min(88, max(0, stepIndex))
        return Int16(predictor)
    }
}

public enum PCMPostprocessor {
    /// Three-point smoothing plus a bounded gain. `gainDB` stays at 0 for MiVoice.
    public static func process(_ input: [Int16], gainDB: Double = 0) -> [Int16] {
        guard !input.isEmpty else { return [] }
        var filtered = input.map(Int.init)
        if input.count >= 3 {
            for index in 1..<(input.count - 1) {
                filtered[index] = (
                    Int(input[index - 1]) + 2 * Int(input[index]) + Int(input[index + 1])
                ) >> 2
            }
        }
        let finiteGainDB = gainDB.isFinite ? gainDB : 0
        let safeGainDB = min(24.0, max(-24.0, finiteGainDB))
        let gain = pow(10.0, safeGainDB / 20.0)
        return filtered.map { value in
            let scaled = Int((Double(value) * gain).rounded())
            return Int16(min(32_767, max(-32_768, scaled)))
        }
    }
}

public struct FrameAccumulator {
    private(set) var pending = Data()
    public init() {}

    public mutating func append(_ data: Data, frameSize: Int) -> [Data] {
        guard frameSize > 0 else { return [] }
        pending.append(data)
        var frames: [Data] = []
        while pending.count >= frameSize {
            frames.append(pending.prefix(frameSize))
            pending.removeFirst(frameSize)
        }
        return frames
    }

    public mutating func reset() {
        pending.removeAll(keepingCapacity: true)
    }
}
