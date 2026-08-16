import Foundation

/// Turns microphone audio into live text for the chat composer. Mirrors `LLMServiceProtocol`'s
/// shape so `ChatViewModel` can be built against a mock in previews/tests without touching real
/// hardware.
@MainActor
protocol SpeechRecognitionServiceProtocol {
    /// Prompts the system permission dialogs (first launch only) and returns whether both
    /// microphone and speech-recognition access were granted.
    func requestAuthorization() async -> Bool

    /// Starts listening and yields the running transcript each time it updates. Each element is
    /// the FULL current transcript, not a delta — the caller just assigns it straight to the
    /// composer text. Finishes cleanly when `stop()` is called; throws if the recognizer/session
    /// fails.
    func startTranscribing(locale: Locale) -> AsyncThrowingStream<String, Error>

    /// Ends the current listening session, if any. Safe to call when not listening.
    func stop()
}
