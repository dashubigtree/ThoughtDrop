import AVFoundation
import Speech
import ThoughtCore

@MainActor
final class AudioCapture: NSObject, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var continuation: CheckedContinuation<String, Error>?
    private var timeout: Task<Void, Never>?
    private var recognitionID: UUID?
    var didFinish: ((Double, String?) -> Void)?
    private var elapsed: Double = 0

    func start(at url: URL) async throws {
        let allowed = await AVCaptureDevice.requestAccess(for: .audio)
        guard allowed else { throw ThoughtError.message("需要麥克風權限。請到系統設定 → 隱私權與安全性 → 麥克風開啟。") }
        let recorder = try AVAudioRecorder(url: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ])
        recorder.delegate = self
        guard recorder.record(forDuration: 55) else { throw ThoughtError.message("無法開始錄音，請檢查麥克風與儲存空間。") }
        self.recorder = recorder
        elapsed = 0
    }

    var duration: Double { recorder?.currentTime ?? elapsed }

    func stop() {
        elapsed = recorder?.currentTime ?? elapsed
        recorder?.stop()
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            guard self.recorder === recorder else { return }
            let duration = self.elapsed > 0 ? self.elapsed : 55
            self.recorder = nil
            self.didFinish?(duration, flag ? nil : "錄音中斷，已保留音檔，請重試辨識。")
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in
            guard self.recorder === recorder else { return }
            self.elapsed = recorder.currentTime
            self.recorder = nil
            self.didFinish?(self.elapsed, "錄音編碼失敗：\(error?.localizedDescription ?? "未知原因")")
        }
    }

    func transcribe(url: URL, localOnly: Bool) async throws -> String {
        let authorization = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard authorization == .authorized else {
            throw ThoughtError.message("需要語音辨識權限。請到系統設定 → 隱私權與安全性 → 語音辨識開啟。")
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-TW")), recognizer.isAvailable else {
            throw ThoughtError.message("繁體中文語音辨識目前不可用，音檔已保留。")
        }
        if localOnly && !recognizer.supportsOnDeviceRecognition {
            throw ThoughtError.message("此 Mac 的繁體中文離線辨識不可用。可在設定允許 Apple 線上辨識後重試。")
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = localOnly
        request.addsPunctuation = true
        let id = UUID()
        recognitionID = id
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            recognitionTask = recognizer.recognitionTask(with: request) { result, error in
                Task { @MainActor in
                    guard self.recognitionID == id else { return }
                    if let result, result.isFinal {
                        let text = result.bestTranscription.formattedString
                        self.finish(text.isEmpty ? .failure(ThoughtError.message("未辨識到語音，音檔已保留。")) : .success(text))
                    } else if let error { self.finish(.failure(error)) }
                }
            }
            timeout = Task { @MainActor in
                do { try await Task.sleep(nanoseconds: 90_000_000_000) }
                catch { return }
                self.finish(.failure(ThoughtError.message("語音辨識逾時，音檔已保留，可稍後重試。")))
            }
        }
    }

    private func finish(_ result: Result<String, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        recognitionID = nil
        timeout?.cancel(); timeout = nil
        recognitionTask?.cancel(); recognitionTask = nil
        continuation.resume(with: result)
    }
}
