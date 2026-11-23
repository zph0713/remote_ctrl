// SPDX-License-Identifier: GPL-3.0-only
import AVFoundation
import AudioToolbox
import CoreAudio

/// Captures the Mac's built-in microphone only to drive a level meter in
/// Settings. It never feeds speech recognition, never writes audio to disk,
/// and is stopped when the settings window closes.
final class MacMicMonitor {
    private var engine: AVAudioEngine?
    private var tapInstalled = false
    private(set) var isRunning = false
    private(set) var error: String?
    private(set) var deviceName = ""
    var onLevel: ((Float) -> Void)?

    var authorizationStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    func requestAccess(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
    }

    @discardableResult
    func start() -> Bool {
        stop()
        guard authorizationStatus == .authorized else {
            error = "未授权麦克风"
            return false
        }
        guard let device = CoreAudioDeviceCatalog.builtInInputDevice() else {
            error = "未找到内建麦克风"
            return false
        }
        let engine = AVAudioEngine()
        guard let unit = engine.inputNode.audioUnit else {
            error = "无法打开内建麦克风"
            return false
        }
        var id = device.id
        let result = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            UInt32(MemoryLayout.size(ofValue: id))
        )
        guard result == noErr else {
            error = "无法选择内建麦克风（\(result)）"
            return false
        }
        let format = engine.inputNode.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            error = "内建麦克风格式不可用"
            return false
        }
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self,
                  let channel = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            guard count > 0 else { return }
            var sum: Float = 0
            for index in 0 ..< count {
                let value = channel[index]
                sum += value * value
            }
            let rms = Float(sqrt(Double(sum) / Double(count)))
            DispatchQueue.main.async {
                self.onLevel?(rms)
            }
        }
        tapInstalled = true
        do {
            engine.prepare()
            try engine.start()
            self.engine = engine
            deviceName = device.name
            error = nil
            isRunning = true
            return true
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
            engine.stop()
            self.error = "无法启动内建麦克风：\(error.localizedDescription)"
            return false
        }
    }

    func stop() {
        if tapInstalled {
            engine?.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine?.stop()
        engine = nil
        isRunning = false
        deviceName = ""
        onLevel?(0)
    }
}
