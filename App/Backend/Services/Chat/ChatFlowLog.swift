import Foundation

/// A single, correlated trace of one chat turn as it moves through the pipeline —
/// input → refine → translate → generate → translate-back → output.
///
/// The pipeline spans three types (`ChatService`, `LanguageValidationService`,
/// `MedicalChatOrchestrator`) that used to each `print` in isolation, so a single turn's
/// story was scattered across unlabelled lines that interleaved badly under concurrency
/// (detect + refine run in parallel). `ChatFlowLog` gives every turn a short id and prints
/// each stage as one aligned, boxed line, so the whole flow reads top-to-bottom at a glance:
///
///   ┌─ chat 3f2a ─────────────────────────────
///   │ ▶ INPUT        vi   "Tôi đau bụng, vết mổ sưng…"
///   │ · refine            "Tôi đau bụng, vết mổ sưng…"
///   │ · name pinned       "Hanh"
///   │ · translate→en      "I have a stomachache, the incision…"
///   │ · rag               5 chunks · conf 0.96
///   │ · generate→en       "I'm sorry to hear that, Hanh. It sounds…"
///   │ · translate→vi      "Tôi rất tiếc khi nghe điều đó, Hanh…"
///   │ · verify            ok (llm)
///   │ ■ OUTPUT       vi   "Tôi rất tiếc khi nghe điều đó, Hanh…"
///   └─────────────────────────────────────────
///
/// Logging is behind `isEnabled` (default true in DEBUG only) so it never ships noise to
/// release builds. It is best-effort observability, never load-bearing: a stage that forgets
/// to log still runs correctly.
struct ChatFlowLog {

    /// Master switch. Compiled to `false` in release builds so no flow text is emitted there.
    #if DEBUG
    static var isEnabled = true
    #else
    static var isEnabled = false
    #endif

    /// Short, human-scannable correlation id for this turn (first 4 hex of a UUID).
    let id: String

    init() {
        self.id = String(UUID().uuidString.prefix(4)).lowercased()
    }

    // MARK: - Lifecycle

    /// Opens the box and logs the raw user input plus the detected language.
    func input(_ text: String, language: String) {
        guard Self.isEnabled else { return }
        print("┌─ chat \(id) " + String(repeating: "─", count: 34))
        line("▶ INPUT", detail: text, tag: language, marker: "│ ")
    }

    /// Logs one intermediate stage: a labelled step with a text sample.
    /// `tag` is an optional short annotation shown before the text (e.g. "en", "vi").
    func stage(_ label: String, _ text: String, tag: String? = nil) {
        guard Self.isEnabled else { return }
        line("· \(label)", detail: text, tag: tag, marker: "│ ")
    }

    /// Logs a stage that carries a metric rather than a text sample (e.g. RAG counts).
    func note(_ label: String, _ note: String) {
        guard Self.isEnabled else { return }
        print("│ " + pad("· \(label)") + note)
    }

    /// Logs the final delivered output and closes the box.
    func output(_ text: String, language: String) {
        guard Self.isEnabled else { return }
        line("■ OUTPUT", detail: text, tag: language, marker: "│ ")
        print("└" + String(repeating: "─", count: 45))
    }

    /// Closes the box early with a short reason (refusal, emergency template, error).
    func end(_ reason: String) {
        guard Self.isEnabled else { return }
        print("│ ✕ END          \(reason)")
        print("└" + String(repeating: "─", count: 45))
    }

    // MARK: - Formatting

    // Left-column width so labels and text samples line up down the box.
    private static let labelWidth = 15
    // Max characters of any text sample before it is elided — keeps one line per stage.
    private static let sampleWidth = 60

    private func line(_ label: String, detail: String, tag: String?, marker: String) {
        let tagCol = tag.map { pad($0, to: 5) } ?? String(repeating: " ", count: 5)
        print(marker + pad(label) + tagCol + " " + quote(detail))
    }

    private func pad(_ s: String, to width: Int = ChatFlowLog.labelWidth) -> String {
        s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
    }

    /// One-line, elided, newline-collapsed quoted sample of a text field.
    private func quote(_ text: String) -> String {
        let flat = text
            .replacingOccurrences(of: "\n", with: " ⏎ ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let clipped = flat.count > Self.sampleWidth
            ? String(flat.prefix(Self.sampleWidth)) + "…"
            : flat
        return "\"\(clipped)\""
    }
}
