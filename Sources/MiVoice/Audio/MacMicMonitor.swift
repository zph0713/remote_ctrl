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
    var onError: ((String) -> Void)?
    private var receivedBuffer = false
    private var generation = 0

    var authorizationStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    func requestAccess(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
    }

    @discardableResult
    func start() -> Bool {
        stop()
        generation += 1
        let currentGeneration = generation
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
        // The tap format is the format the input node *produces*; using the
        // input format here can yield a zero-channel or mismatched tap.
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            error = "内建麦克风格式不可用"
            return false
        }
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self, let channels = buffer.floatChannelData else { return }
            let frameCount = Int(buffer.frameLength)
            let channelCount = Int(buffer.format.channelCount)
            guard frameCount > 0, channelCount > 0 else { return }
            // Average every channel; some devices leave channel 0 silent.
            var sum: Double = 0
            var sampleCount = 0
            for channel in 0 ..< channelCount {
                let data = channels[channel]
                for index in 0 ..< frameCount {
                    let value = Double(data[index])
                    sum += value * value
                }
                sampleCount += frameCount
            }
            guard sampleCount > 0 else { return }
            self.receivedBuffer = true
            let rms = Float(sqrt(sum / Double(sampleCount)))
            DispatchQueue.main.async {
                self.onLevel?(rms)
            }
        }
        tapInstalled = true
        receivedBuffer = false
        do {
            engine.prepare()
            try engine.start()
            // AVAudioEngine can report running while the selected input device
            // is still stopped; start it explicitly and confirm the binding.
            var bound = AudioDeviceID(0)
            var boundSize = UInt32(MemoryLayout<AudioDeviceID>.size)
            let boundOK = AudioUnitGetProperty(
                unit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &bound,
                &boundSize
            ) == noErr && bound == device.id
            guard boundOK else {
                engine.inputNode.removeTap(onBus: 0)
                tapInstalled = false
                engine.stop()
                error = "内建麦克风绑定失败"
                return false
            }
            _ = AudioDeviceStart(device.id, nil)
            self.engine = engine
            deviceName = device.name
            error = nil
            isRunning = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self.generation == currentGeneration,
                      self.isRunning, !self.receivedBuffer else { return }
                self.onError?("没有收到内建麦克风数据")
            }
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
        generation += 1
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
