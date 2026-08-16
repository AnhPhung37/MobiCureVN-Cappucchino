import AVFoundation
import Foundation

/// Wraps `AVSpeechSynthesizer` to read chat replies aloud — entirely on-device, matching the
/// rest of the app's offline-first design.
@MainActor
final class TextToSpeechService: NSObject, TextToSpeechServiceProtocol {
    private let synthesizer = AVSpeechSynthesizer()
    private var onFinish: (@MainActor () -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, locale: Locale, onFinish: @escaping @MainActor () -> Void) {
        stop()

        let utterance = AVSpeechUtterance(string: Self.plainText(fromMarkdown: text))
        utterance.voice = AVSpeechSynthesisVoice(language: locale.identifier)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate

        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: .duckOthers)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            return
        }

        self.onFinish = onFinish
        synthesizer.speak(utterance)
    }

    func stop() {
        guard synthesizer.isSpeaking else { return }
        // .immediate (not .word) — the patient tapped to stop, so cut off right away rather
        // than finishing the current word.
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// Strips markdown formatting (`**bold**`, `# headers`, `[text](url)`, …) so the synthesizer
    /// doesn't read out literal asterisks and brackets. Reuses `AttributedString`'s markdown
    /// parser — the same one `MessageBubble` uses to render the text — and takes just its plain
    /// characters.
    private static func plainText(fromMarkdown markdown: String) -> String {
        guard let attributed = try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return markdown
        }
        return String(attributed.characters)
    }
}

extension TextToSpeechService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            let callback = self.onFinish
            self.onFinish = nil
            callback?()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        // A cancel is always caused by our own stop()/speak(), whose caller already updated its
        // state directly — reporting onFinish here too would be a spurious second completion.
        Task { @MainActor in self.onFinish = nil }
    }
}
