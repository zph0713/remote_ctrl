import XCTest
@testable import MiVoiceCore

final class ATVVTests: XCTestCase {
    func testCapabilitiesParseV10SixteenKilohertz() {
        // opcode, version 0x0100, codecs 0x02, interaction 0x03, frame 0x0078
        let data = Data([0x0B, 0x01, 0x00, 0x02, 0x03, 0x00, 0x78])
        let caps = ATVVCapabilities.parse(data)
        XCTAssertEqual(caps?.version, 0x0100)
        XCTAssertEqual(caps?.codecs, 0x02)
        XCTAssertEqual(caps?.interaction, 0x03)
        XCTAssertEqual(caps?.frameSize, 120)
        XCTAssertEqual(caps?.selectedCodec, 0x02)
        XCTAssertEqual(caps?.sampleRate, 16_000)
    }

    func testCapabilitiesRejectsWrongOpcode() {
        XCTAssertNil(ATVVCapabilities.parse(Data([0x0A, 0x01, 0x00, 0x02, 0x03, 0x00, 0x78])))
    }

    func testCapabilitiesDefaultsZeroFrameSizeTo120() {
        let data = Data([0x0B, 0x01, 0x00, 0x02, 0x03, 0x00, 0x00])
        XCTAssertEqual(ATVVCapabilities.parse(data)?.frameSize, 120)
    }

    func testCapabilitiesMirrorsCodecIntoInteractionByte() {
        let data = Data([0x0B, 0x01, 0x00, 0x00, 0x02, 0x00, 0x78, 0x00, 0x00])
        let caps = ATVVCapabilities.parse(data)
        XCTAssertEqual(caps?.selectedCodec, 0x02)
        XCTAssertEqual(caps?.interaction, 0x03)
        XCTAssertEqual(caps?.sampleRate, 16_000)
    }

    func testOldFirmwareLayout() {
        // version 0x0010, eight-byte body with codec at index 4 and frame at 7...8
        let data = Data([0x0B, 0x00, 0x10, 0x00, 0x02, 0x00, 0x00, 0x00, 0x78])
        let caps = ATVVCapabilities.parse(data)
        XCTAssertEqual(caps?.version, 0x0010)
        XCTAssertEqual(caps?.selectedCodec, 0x02)
        XCTAssertEqual(caps?.frameSize, 120)
    }

    func testDecoderZeroBytesStaySilent() {
        let decoder = IMAADPCMDecoder()
        let samples = decoder.decode(Data([0x00, 0x00, 0x00, 0x00]))
        XCTAssertEqual(samples.count, 8)
        XCTAssertEqual(samples, [Int16](repeating: 0, count: 8))
    }

    func testDecoderMatchesKnownRC003Vectors() {
        let decoder = IMAADPCMDecoder()
        XCTAssertEqual(decoder.decode(Data([0x11])), [1, 2])
        decoder.reset()
        XCTAssertEqual(decoder.decode(Data([0x7F])), [11, -19])
    }

    func testDecoderNeverOverflowsInt16() {
        let decoder = IMAADPCMDecoder()
        let samples = decoder.decode(Data(repeating: 0xFF, count: 512))
        XCTAssertEqual(samples.count, 1024)
        XCTAssertEqual(samples.allSatisfy { $0 >= Int16.min && $0 <= Int16.max }, true)
    }

    func testDecoderHighNibbleFirst() {
        let decoder = IMAADPCMDecoder()
        // 0x70 => high nibble 7, low nibble 0
        let samples = decoder.decode(Data([0x70]))
        XCTAssertEqual(samples.count, 2)
        XCTAssertNotEqual(samples[0], samples[1])
        XCTAssertEqual(samples[0] > 0, true)
    }

    func testPostprocessorClampsGain() {
        let input: [Int16] = [1_000, 2_000, 3_000]
        let output = PCMPostprocessor.process(input, gainDB: 100)
        XCTAssertEqual(output.count, input.count)
        XCTAssertEqual(output.allSatisfy { $0 >= Int16.min && $0 <= Int16.max }, true)
    }

    func testFrameAccumulatorKeepsRemainder() {
        var accumulator = FrameAccumulator()
        let first = accumulator.append(Data(repeating: 1, count: 100), frameSize: 40)
        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(accumulator.pending.count, 20)
        let second = accumulator.append(Data(repeating: 2, count: 20), frameSize: 40)
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(accumulator.pending.count, 0)
    }

    func testMicrophoneCommands() {
        XCTAssertEqual(ATVVProtocol.microphoneOpen(version: 0x0100, codec: 0x02), Data([0x0C, 0x00]))
        XCTAssertEqual(ATVVProtocol.microphoneOpen(version: 0x0001, codec: 0x02), Data([0x0C, 0x00, 0x02]))
        XCTAssertEqual(ATVVProtocol.microphoneClose(version: 0x0100, sessionID: 7), Data([0x0D, 0x07]))
        XCTAssertEqual(ATVVProtocol.microphoneClose(version: 0x0001, sessionID: 7), Data([0x0D]))
    }
}

final class HIDReportParserTests: XCTestCase {
    func testSixByteReport() {
        let usages = HIDReportParser.usages(reportID: 1, bytes: [0x28, 0x00, 0x00, 0x00, 0x00, 0x00])
        XCTAssertEqual(usages, [0x28])
    }

    func testSevenByteReportWithIDPrefix() {
        let usages = HIDReportParser.usages(reportID: 1, bytes: [0x01, 0x4A, 0x00, 0x00, 0x00, 0x00, 0x00])
        XCTAssertEqual(usages, [0x4A])
    }

    func testMultipleUsages() {
        let usages = HIDReportParser.usages(reportID: 1, bytes: [0x3E, 0x00, 0x52, 0x00, 0x00, 0x00])
        XCTAssertEqual(usages, [0x3E, 0x52])
    }

    func testRejectsOtherReportIDs() {
        XCTAssertNil(HIDReportParser.usages(reportID: 2, bytes: [0x28, 0x00]))
    }

    func testRejectsOddLength() {
        XCTAssertNil(HIDReportParser.usages(reportID: 1, bytes: [0x28, 0x00, 0x00]))
    }
}

final class SettingsTests: XCTestCase {
    func testDefaultBindingsCoverEveryButton() {
        let settings = AppSettings()
        for button in RemoteButton.allCases {
            XCTAssertNotNil(settings.bindings[button.rawValue], "missing binding for \(button.rawValue)")
        }
    }

    func testRoundTrip() throws {
        var settings = AppSettings()
        settings.localeIdentifier = "en-US"
        settings.setBinding(.shortcut(keyCode: 36, flags: 0x100000), for: .ok)
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded, settings)
    }

    func testMissingKeysUseDefaults() throws {
        let json = Data(#"{"localeIdentifier":"en-US"}"#.utf8)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertEqual(decoded.localeIdentifier, "en-US")
        XCTAssertEqual(decoded.bindings.count, RemoteButton.allCases.count)
        XCTAssertEqual(decoded.showHUD, true)
    }

    func testVoiceModeDefaultsToLocalApple() {
        let settings = AppSettings()
        XCTAssertEqual(settings.voiceMode, .appleSpeech)
        XCTAssertEqual(settings.virtualDeviceUID, "")
        XCTAssertEqual(settings.lockSystemInput, true)
    }

    func testVoiceModeSurvivesRoundTrip() throws {
        var settings = AppSettings()
        settings.voiceMode = .wechatIME
        settings.virtualDeviceUID = "BlackHole2ch_UID"
        settings.lockSystemInput = false
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded.voiceMode, .wechatIME)
        XCTAssertEqual(decoded.virtualDeviceUID, "BlackHole2ch_UID")
        XCTAssertEqual(decoded.lockSystemInput, false)
    }

    func testUnknownBindingKindFallsBackToNone() throws {
        let json = Data(#"{"kind":"fromTheFuture"}"#.utf8)
        let decoded = try JSONDecoder().decode(ButtonBinding.self, from: json)
        XCTAssertEqual(decoded.kind, .none)
    }
}
