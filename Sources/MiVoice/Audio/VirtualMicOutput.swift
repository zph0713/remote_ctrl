// SPDX-License-Identifier: GPL-3.0-only
// AVAudioEngine virtual-microphone routing adapted from
// ericyangpan/mi-remote-helper (GPL-3.0-only). See NOTICE.
import AVFoundation
import AudioToolbox
import CoreAudio

/// Writes decoded RC003 PCM into a loopback output device (BlackHole /
/// MiRemoteV). The input method records from the matching input side.
final class VirtualMicOutput {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var format: AVAudioFormat?
    private var generation: UInt64 = 0
    private var drainCompletion: (() -> Void)?
    private(set) var queuedFrames = 0
    private(set) var error: String?
    private(set) var deviceUID = ""
    private var selectedDeviceID: AudioDeviceID = 0

    var isReady: Bool {
        guard engine?.isRunning == true,
              let unit = engine?.outputNode.audioUnit else { return false }
        var current = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioUnitGetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &current,
            &size
        ) == noErr && current == selectedDeviceID
    }

    func configure(uid: String) -> Bool {
        stop()
        let devices = CoreAudioDeviceCatalog.loopbackDevices()
        guard let device = devices.first(where: { $0.uid == uid }) ?? devices.first else {
            error = "未找到虚拟麦克风，请安装 BlackHole 2ch"
            return false
        }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1) else {
            error = "无法创建虚拟麦克风音频格式"
            return false
        }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        guard let unit = engine.outputNode.audioUnit else {
            error = "无法打开虚拟麦克风输出"
            engine.stop()
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
            error = "无法连接虚拟麦克风（\(result)）"
            engine.stop()
            return false
        }
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do {
            engine.prepare()
            try engine.start()
            player.play()
            self.engine = engine
            self.player = player
            self.format = format
            selectedDeviceID = device.id
            deviceUID = device.uid
            error = nil
            return true
        } catch {
            self.error = "无法启动虚拟麦克风：\(error.localizedDescription)"
            engine.stop()
            return false
        }
    }

    @discardableResult
    func enqueue(_ samples: [Int16], completion: (() -> Void)? = nil) -> Bool {
        guard !samples.isEmpty, isReady, let player, let format else { return false }
        // Bound latency and memory to one second if the device stops consuming.
        guard queuedFrames + samples.count <= 16_000,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(samples.count)
              ),
              let channel = buffer.floatChannelData?[0] else {
            error = "虚拟麦克风缓冲已满，请重新连接"
            return false
        }
        for index in samples.indices {
            channel[index] = Float(samples[index]) / 32_768.0
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        queuedFrames += samples.count
        let token = generation
        let frameCount = samples.count
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.queuedFrames = max(0, self.queuedFrames - frameCount)
                completion?()
                if self.queuedFrames == 0 {
                    let drained = self.drainCompletion
                    self.drainCompletion = nil
                    drained?()
                }
            }
        }
        return true
    }

    func beginSession() {
        drainCompletion = nil
        generation &+= 1
        queuedFrames = 0
        player?.stop()
        if isReady { player?.play() }
    }

    func whenDrained(_ completion: @escaping () -> Void) {
        if queuedFrames == 0 { completion() }
        else { drainCompletion = completion }
    }

    func cancelDrain() {
        drainCompletion = nil
    }

    func stop() {
        drainCompletion = nil
        generation &+= 1
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
        format = nil
        queuedFrames = 0
        deviceUID = ""
        selectedDeviceID = 0
    }
}
