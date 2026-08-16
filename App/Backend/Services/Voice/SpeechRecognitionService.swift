import AVFoundation
import Foundation
import Speech

/// Wraps `SFSpeechRecognizer` + `AVAudioEngine` to turn the microphone into live text for the
/// chat composer. Prefers on-device recognition when the locale supports it, consistent with the
/// rest of the app's offline-first design — but unlike the RAG/LLM stack this isn't a hard
/// guarantee: `SFSpeechRecognizer` silently falls back to the server path when on-device isn't
/// available for a given language/device.
@MainActor
final class SpeechRecognitionService: SpeechRecognitionServiceProtocol {

    enum TranscriptionError: LocalizedError {
        case recognizerUnavailable

        var errorDescription: String? {
            switch self {
            case .recognizerUnavailable:
                return "Không thể sử dụng nhận dạng giọng nói cho ngôn ngữ này lúc này.".localized(for: .current)
            }
        }
    }

    private let audioEngine = AVAudioEngine()
    private var task: SFSpeechRecognitionTask?
    private var continuation: AsyncThrowingStream<String, Error>.Continuation?

    func requestAuthorization() async -> Bool {
        let speechStatus = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard speechStatus == .authorized else { return false }

        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func startTranscribing(locale: Locale) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
                continuation.finish(throwing: TranscriptionError.recognizerUnavailable)
                return
            }

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition

            let audioSession = AVAudioSession.sharedInstance()
            do {
                try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
                try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            } catch {
                continuation.finish(throwing: error)
                return
            }

            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
                request.append(buffer)
            }

            audioEngine.prepare()
            do {
                try audioEngine.start()
            } catch {
                inputNode.removeTap(onBus: 0)
                continuation.finish(throwing: error)
                return
            }

            self.continuation = continuation
            task = recognizer.recognitionTask(with: request) { result, error in
                if let result {
                    continuation.yield(result.bestTranscription.formattedString)
                }
                // A user-initiated `stop()` cancels the task, which also reports an error here —
                // `stop()` already finished the continuation cleanly by that point, so this is a
                // harmless no-op rather than a surfaced failure.
                if let error {
                    continuation.finish(throwing: error)
                }
            }

            // Safety net for the consumer cancelling the surrounding Task directly instead of
            // calling `stop()` (e.g. the view model deallocates mid-session).
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.stop() }
            }
        }
    }

    func stop() {
        guard audioEngine.isRunning else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        task?.cancel()
        task = nil
        continuation?.finish()
        continuation = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
