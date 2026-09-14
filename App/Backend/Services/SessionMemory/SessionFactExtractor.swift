import Foundation

/// Extracts durable, self-descriptive facts from a single user turn using the on-device LLM.
///
/// "Durable" means information about the patient that stays true across the session and is
/// worth remembering even after the turn scrolls out of the short history window — name, age,
/// allergies, current wound location, ongoing medications, relevant conditions. Transient
/// questions ("what should I eat today?") carry no such facts and yield nothing.
///
/// Runs on the English text, consistent with the rest of `MedicalChatOrchestrator`'s layer,
/// so extracted facts are stored in English. Mirrors `LanguageValidationService`'s LLM
/// conventions: a single `LLMRequest(userMessage:)`, drain the stream, strip any Qwen
/// `<think>` preamble, and fail *closed* to an empty result on any parse trouble — a missed
/// fact is a far better failure mode for a medical app than a hallucinated one polluting the
/// remembered profile.
nonisolated struct SessionFactExtractor {

    /// Extract zero or more facts from `userText`. Returns `[]` when the turn states nothing
    /// durable, when the model returns unparseable output, or when generation fails.
    func extract(
        from userText: String,
        using llmService: LLMServiceProtocol
    ) async -> [SessionFactStore.SessionFact] {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        // Deterministic gate before the LLM, mirroring how LanguageValidationService gates
        // `refine`. This call is a second full generation on every single turn, and on a turn
        // that states nothing about the patient it can only ever return `[]` — but it still
        // holds the one ModelContainer, so the user's NEXT message queues behind it.
        guard Self.statesDurableFact(trimmed) else { return [] }

        let prompt = """
        Extract durable facts the user states ABOUT THEMSELVES from the MESSAGE below — \
        their name, age, sex, allergies, current wound or injury location, ongoing \
        medications, and relevant medical conditions. Only include facts the user explicitly \
        states about themselves; ignore general questions, greetings, and anything not about \
        the user.

        Reply with a JSON array of objects, each having a "key" and a "value". Use these \
        lowercase snake_case keys where they apply: name, age, sex, allergy, wound_location, \
        medication, condition. Keep each value short. If the message states no such facts, \
        reply with exactly [].

        Reply with ONLY the JSON array, nothing else.

        MESSAGE: \(trimmed)
        """

        // Short JSON array, parsed strictly — greedy decoding, and a ceiling far below the
        // answering budget so a model that starts explaining itself instead of emitting JSON is
        // cut off rather than holding the shared ModelContainer for 1024 tokens.
        let stream = llmService.stream(request: LLMRequest(
            userMessage: prompt,
            options: .extraction
        ))
        var reply = ""
        for await token in stream {
            reply += token
        }

        return Self.parse(reply)
    }

    // MARK: - Gate

    /// Whether `text` may state something durable about the patient — the deterministic gate in
    /// front of both post-answer LLM passes (this extractor and `ProfileUpdateExtractor`).
    ///
    /// Matched on whole WORDS and word sequences, not substrings. The first version matched
    /// substrings, so "my " fired inside "urostomy ", "me " inside "syndrome " and "time ", and
    /// topic words ("stoma", "surgery", "hậu môn nhân tạo") fired on every question that merely
    /// named the topic: on the golden set it ran both passes for 78 of 209 plain questions, which
    /// is barely a gate. Cues are now self-reference and self-report only, so a question that
    /// names a topic without saying anything about the asker skips.
    ///
    /// Still deliberately over-inclusive — a false positive costs one generation that returns
    /// `[]`, a false negative silently forgets a fact — which is why Vietnamese self-report verbs
    /// that usually drop their subject ("bị đau bụng", "mới mổ tuần trước") count on their own.
    ///
    /// `MedicalChatOrchestrator` calls this with the translated ENGLISH text, so the English cues
    /// carry the weight in practice. The Vietnamese cues (with and without diacritics, since
    /// patients type both) are here because nothing in the signature enforces that language.
    /// `Pipeline/tools/measure_aux_gate.py` parses this list and reports the fire rate.
    static func statesDurableFact(_ text: String) -> Bool {
        let words = gateWords(in: text)
        guard !words.isEmpty else { return false }
        return disclosureCues.contains { cue in
            guard cue.count <= words.count else { return false }
            return (0...(words.count - cue.count)).contains { start in
                cue.indices.allSatisfy { words[start + $0] == cue[$0] }
            }
        }
    }

    /// Each cue is one word, or a sequence of adjacent words.
    private static let disclosureCues: [[String]] = [
        // Vietnamese — self-reference (with and without diacritics)
        "tôi", "toi", "tui", "mình", "minh", "em", "cháu", "chau", "tên tôi", "ten toi",
        "tuổi", "tuoi",
        // Vietnamese — self-report, usually with the subject dropped
        "bị", "bi", "dị ứng", "di ung", "đang dùng", "dang dung", "đang uống", "dang uong",
        "đang điều trị", "dang dieu tri", "được chẩn đoán", "duoc chan doan",
        "đã mổ", "da mo", "mới mổ", "moi mo", "vừa mổ", "vua mo",
        "đã phẫu thuật", "da phau thuat", "mới phẫu thuật", "moi phau thuat",
        "vừa phẫu thuật", "vua phau thuat",
        // English — self-reference
        "i'm", "im", "i am", "my", "i've", "i have", "i had", "i was", "i got", "i take", "i use",
        // English — self-report with the subject dropped
        "allergic to", "diagnosed with", "was prescribed", "been prescribed", "taking",
        "years old", "year old",
    ].map { $0.split(separator: " ").map(String.init) }

    /// Lowercased words of `text` — letters, digits and in-word apostrophes — in NFC, so a
    /// decomposed "ô" from some keyboards matches the precomposed cue, and "year-old" reads as
    /// "year old".
    private static func gateWords(in text: String) -> [String] {
        text.precomposedStringWithCanonicalMapping
            .lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .split { !($0.isLetter || $0.isNumber || $0 == "'") }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Private

    /// Parse the model's reply into facts. Tolerant by design: strips a `<think>` preamble,
    /// isolates the first `[...]` array (models sometimes wrap it in prose despite the
    /// instruction), and decodes it. Anything unparseable yields `[]`.
    static func parse(_ reply: String) -> [SessionFactStore.SessionFact] {
        let cleaned = stripThinking(reply).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let json = firstJSONArray(in: cleaned),
              let data = json.data(using: .utf8) else { return [] }

        guard let raw = try? JSONDecoder().decode([RawFact].self, from: data) else { return [] }

        return raw.compactMap { item in
            let key = item.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = item.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty else { return nil }
            return SessionFactStore.SessionFact(key: key, value: value)
        }
    }

    /// A model may emit numeric ages/values, so decode `value` leniently as string-or-number.
    private struct RawFact: Decodable {
        let key: String
        let value: String

        enum CodingKeys: String, CodingKey { case key, value }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            key = (try? c.decode(String.self, forKey: .key)) ?? ""
            if let s = try? c.decode(String.self, forKey: .value) {
                value = s
            } else if let n = try? c.decode(Int.self, forKey: .value) {
                value = String(n)
            } else if let d = try? c.decode(Double.self, forKey: .value) {
                value = String(d)
            } else {
                value = ""
            }
        }
    }

    /// Extract the first top-level `[...]` substring, so surrounding prose doesn't break JSON
    /// decoding. Returns `nil` if no balanced array is found.
    private static func firstJSONArray(in text: String) -> String? {
        guard let start = text.firstIndex(of: "[") else { return nil }
        var depth = 0
        var index = start
        while index < text.endIndex {
            let ch = text[index]
            if ch == "[" { depth += 1 }
            else if ch == "]" {
                depth -= 1
                if depth == 0 {
                    return String(text[start...index])
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// Removes a `<think>…</think>` reasoning preamble Qwen-class models can emit even with
    /// thinking disabled. Mirrors `LanguageValidationService.stripThinking`.
    private static func stripThinking(_ reply: String) -> String {
        reply.replacingOccurrences(
            of: "(?s)<think>.*?(</think>|$)",
            with: "",
            options: .regularExpression
        )
    }
}
