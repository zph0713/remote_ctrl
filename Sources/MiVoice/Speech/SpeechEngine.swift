import AVFoundation
import Foundation
import Speech

/// Local-only speech recognition. Every request sets
/// `requiresOnDeviceRecognition = true`; if the offline model is missing the
/// request fails instead of silently sending audio to a server.
final class SpeechEngine {
    enum State: Equatable {
        case idle
        case listening
        case finishing
    }

    private(set) var state: State = .idle {
        didSet {
            if oldValue != state {
                onStateChange?(state)
            }
        }
    }

    var onFinal: ((String) -> Void)?
    var onPartial: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onStateChange: ((State) -> Void)?

    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var format: AVAudioFormat?
    private var bestText = ""
    private var session = UUID()
    private var finishing = false
    private var delivered = false
    private var timeoutWork: DispatchWorkItem?

    static func requestAuthorization(_ completion: @escaping (SFSpeechRecognizerAuthorizationStatus) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                completion(status)
            }
        }
    }

    static var authorizationStatus: SFSpeechRecognizerAuthorizationStatus {
        SFSpeechRecognizer.authorizationStatus()
    }

    static func authorizationText() -> String {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return "已授权"
        case .denied: return "已拒绝"
        case .restricted: return "受系统限制"
        case .notDetermined: return "未授权"
        @unknown default: return "未知"
        }
    }

    static func diagnostics(localeIdentifier: String) -> String {
        let locale = Locale(identifier: localeIdentifier)
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            return "该语言无法创建识别器：\(localeIdentifier)"
        }
        let supported = SFSpeechRecognizer.supportedLocales().contains(locale)
        return [
            "授权：\(authorizationText())",
            "可用：\(recognizer.isAvailable ? "是" : "否")",
            "离线模型：\(recognizer.supportsOnDeviceRecognition ? "有" : "无")",
            "语言支持：\(supported ? "是" : "否")",
        ].joined(separator: "　")
    }

    @discardableResult
    func start(localeIdentifier: String) -> Bool {
        // A very fast second press can arrive while the previous utterance is
        // still finalizing. Deliver its best transcript instead of dropping it.
        if state == .finishing, !bestText.isEmpty {
            onFinal?(bestText)
        }
        cancel()

        let status = SFSpeechRecognizer.authorizationStatus()
        guard status == .authorized else {
            onError?(status == .denied ? "语音识别权限被拒绝，请在系统设置中开启" : "尚未授权语音识别")
            return false
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)) else {
            onError?("系统语音识别暂不可用")
            return false
        }
        guard recognizer.supportsOnDeviceRecognition else {
            onError?("没有离线语音模型：系统设置 → 键盘 → 听写 → 语言")
            return false
        }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            onError?("无法创建音频格式")
            return false
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.taskHint = .dictation
        request.addsPunctuation = true

        let session = UUID()
        self.session = session
        self.recognizer = recognizer
        self.request = request
        self.format = format
        bestText = ""
        finishing = false
        delivered = false

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                self?.handle(result: result, error: error, session: session)
            }
        }

        state = .listening
        Log.info("speech session started")
        return true
    }

    func append(_ samples: [Int16]) {
        guard state == .listening, !finishing,
              let request, let format, !samples.isEmpty else { return }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData?[0] {
            for index in 0..<samples.count {
                channel[index] = Float(samples[index]) / 32_768.0
            }
        }
        request.append(buffer)
    }

    /// Call when the voice key is released. Waits briefly for the final result.
    func finish() {
        guard state == .listening, !finishing else { return }
        finishing = true
        state = .finishing
        request?.endAudio()

        let session = self.session
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.session == session, !self.delivered else { return }
            if self.bestText.isEmpty {
                self.fail("没有识别到语音")
            } else {
                self.deliver(self.bestText, session: session)
            }
        }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: work)
    }

    func cancel() {
        timeoutWork?.cancel()
        timeoutWork = nil
        task?.cancel()
        task = nil
        request = nil
        recognizer = nil
        format = nil
        session = UUID()
        bestText = ""
        finishing = false
        delivered = false
        state = .idle
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?, session: UUID) {
        guard session == self.session, !delivered else { return }

        if let result {
            let text = result.bestTranscription.formattedString
            if !text.isEmpty {
                let previous = bestText
                bestText = String(text.prefix(20_000))
                if bestText != previous {
                    onPartial?(bestText)
                }
            }
            if result.isFinal {
                deliver(bestText, session: session)
                return
            }
        }

        if error != nil {
            if finishing || !bestText.isEmpty {
                deliver(bestText, session: session)
            } else {
                fail("语音识别失败：\(error?.localizedDescription ?? "未知错误")")
            }
        }
    }

    private func deliver(_ text: String, session: UUID) {
        guard session == self.session, !delivered else { return }
        delivered = true
        timeoutWork?.cancel()
        timeoutWork = nil
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        cleanupAfterDelivery()
        if cleaned.isEmpty {
            onError?("没有识别到语音")
        } else {
            Log.info("speech session produced text")
            onFinal?(cleaned)
        }
    }

    private func fail(_ message: String) {
        guard !delivered else { return }
        delivered = true
        timeoutWork?.cancel()
        timeoutWork = nil
        cleanupAfterDelivery()
        Log.error("speech failed: \(message)")
        onError?(message)
    }

    private func cleanupAfterDelivery() {
        task?.cancel()
        task = nil
        request = nil
        recognizer = nil
        format = nil
        bestText = ""
        finishing = false
        session = UUID()
        state = .idle
    }
}
