import Foundation

/// Reads chat text aloud for patients who'd rather listen than read. Mirrors
/// `SpeechRecognitionServiceProtocol`'s shape so `ChatViewModel` can be built against a mock in
/// previews/tests without touching real hardware.
@MainActor
protocol TextToSpeechServiceProtocol {
    /// Speaks `text` in `locale`, calling `onFinish` when playback ends naturally. Calling this
    /// again (or `stop()`) while already speaking cuts the current utterance short and does NOT
    /// call the previous `onFinish` — only one utterance's completion is ever reported.
    func speak(_ text: String, locale: Locale, onFinish: @escaping @MainActor () -> Void)

    /// Stops playback immediately, if any is in progress. Safe to call when idle.
    func stop()
}
