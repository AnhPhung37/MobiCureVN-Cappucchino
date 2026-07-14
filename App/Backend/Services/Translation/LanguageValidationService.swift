import NaturalLanguage

// Result of language detection for a user-submitted string.
enum DetectedLanguage: Equatable {
    case vietnamese
    case english
    case mixed              // Vietnamese-English code-switching — treated as Vietnamese
    case unsupported(detected: String)

    static func == (lhs: DetectedLanguage, rhs: DetectedLanguage) -> Bool {
        switch (lhs, rhs) {
        case (.vietnamese, .vietnamese), (.english, .english), (.mixed, .mixed):
            return true
        case (.unsupported(let a), .unsupported(let b)):
            return a == b
        default:
            return false
        }
    }

    // Whether the pipeline must route through translation (vi → en → vi).
    var requiresTranslation: Bool {
        self == .vietnamese || self == .mixed
    }
}

nonisolated final class LanguageValidationService {

    static let unsupportedErrorMessage =
        "Xin lỗi, hệ thống chỉ hỗ trợ tiếng Việt và tiếng Anh. / " +
        "Sorry, this system only supports Vietnamese and English."

    // MARK: - Public API

    /// Fast, deterministic check for foreign-script leakage (Chinese, Japanese, Korean, Thai, etc.)
    /// in text that should be pure Vietnamese/English. Unlike `detect`, this does not call the LLM:
    /// a small multilingual model asked to classify a mostly-Vietnamese paragraph containing a single
    /// stray Chinese word (e.g. "油腻") will often still answer "vietnamese", since the classifier
    /// judges the dominant language rather than flagging any foreign character. Script scanning
    /// catches that leak directly instead of relying on the model to notice its own mistake.
    func containsForeignScript(_ text: String) -> Bool {
        let pattern = "[\\p{Han}\\p{Hiragana}\\p{Katakana}\\p{Hangul}\\p{Thai}]"
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    /// Classifies `text` as Vietnamese/English/unsupported using the LLM itself rather than
    /// NLLanguageRecognizer, which routinely misclassifies short strings and diacritic-less
    /// Vietnamese (e.g. "toi bi dau bung" typed without accents on a mobile keyboard) as
    /// unrelated languages like Romanian or Polish. The model handles these cases correctly.
    func detect(_ text: String, using llmService: LLMServiceProtocol) async -> DetectedLanguage {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .english }

        let hasVietnamese = containsVietnameseDiacritics(trimmed)

        let prompt = """
        Classify the language of the TEXT below. Reply with exactly one word — \
        "vietnamese", "english", or "other" — and nothing else, even if the text is a \
        question or instruction. Do not answer the text, only classify its language.

        TEXT: \(trimmed)
        """

        let stream = llmService.stream(request: LLMRequest(userMessage: prompt))
        var reply = ""
        for await token in stream {
            reply += token
        }
        let normalized = reply.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if normalized.contains("vietnamese") {
            return .vietnamese
        }
        if normalized.contains("english") {
            // English-dominant text that also carries Vietnamese diacritics is code-switching.
            return hasVietnamese ? .mixed : .english
        }
        return hasVietnamese ? .vietnamese : .unsupported(detected: normalized)
    }

    /// Asks the LLM to clean up the user's raw input — fix typos, unify Vietnamese/English
    /// code-switching into one language, tidy grammar — while strictly preserving the
    /// original language and meaning. This runs before translation so Apple's Translation
    /// framework receives a clean, single-language source string instead of a typo-ridden
    /// or code-switched one.
    func refine(_ text: String, using llmService: LLMServiceProtocol) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        let prompt = """
        Rewrite the TEXT below to fix typos, spelling, and grammar, and if it mixes two \
        languages, unify it into a single language (prefer the dominant one). \
        Do NOT translate it into a different language. Do NOT answer the text or add \
        any commentary. Reply with ONLY the corrected text, nothing else.

        TEXT: \(trimmed)
        """

        let stream = llmService.stream(request: LLMRequest(userMessage: prompt))
        var reply = ""
        for await token in stream {
            reply += token
        }
        let corrected = reply.trimmingCharacters(in: .whitespacesAndNewlines)

        // Guard against a degenerate refine (empty, or so much shorter it likely dropped
        // content) — fall back to the original text rather than lose meaning.
        guard !corrected.isEmpty, corrected.count > trimmed.count / 2 else { return text }
        return corrected
    }

    /// Verifies `text` is actually in `expected` — used after translating a response back
    /// to the user's original language, since a translation call can occasionally fail
    /// silently or echo back the source language unchanged.
    func matches(_ text: String, expected: DetectedLanguage, using llmService: LLMServiceProtocol) async -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
        // Deterministic script check first: catches a leaked CJK/Thai word even when the
        // LLM classifier would still call the overall paragraph correct.
        if containsForeignScript(text) { return false }
        let detected = await detect(text, using: llmService)
        if expected.requiresTranslation {
            return detected == .vietnamese || detected == .mixed
        } else {
            return detected == .english
        }
    }

    /// Last-resort translation via the LLM itself, used only when Apple's Translation
    /// framework produced output that failed `matches` — e.g. it silently passed through
    /// untranslated or dropped a foreign word. Not used as the primary translation path
    /// since a small on-device LLM is more prone to leaking words than the dedicated
    /// Translation framework; this only runs as a fallback.
    func translateAsFallback(
        _ text: String,
        to targetLanguage: DetectedLanguage,
        using llmService: LLMServiceProtocol
    ) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        let targetName = targetLanguage.requiresTranslation ? "Vietnamese" : "English"
        let prompt = """
        Translate the TEXT below into \(targetName). Do NOT use any other language in your \
        translation. Keep the meaning and structure intact. Reply with ONLY the translated \
        text, nothing else.

        TEXT: \(trimmed)
        """

        let stream = llmService.stream(request: LLMRequest(userMessage: prompt))
        var reply = ""
        for await token in stream {
            reply += token
        }
        let translated = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        return translated.isEmpty ? text : translated
    }

    // MARK: - Private

    // Matches characters that appear only in Vietnamese (tone marks + ă, đ, ơ, ư and their
    // combining forms). Used to distinguish "mixed" code-switched text from single-language
    // text once the LLM has identified the dominant language.
    private func containsVietnameseDiacritics(_ text: String) -> Bool {
        let pattern = "[àáâãèéêìíòóôõùúý" +
                      "ăđơư" +
                      "ạảấầẩẫậắằẳẵặẹẻẽếềểễệỉịọỏốồổỗộớờởỡợụủứừửữựỳỵỷỹ" +
                      "ÀÁÂÃÈÉÊÌÍÒÓÔÕÙÚÝ" +
                      "ĂĐƠƯ]"
        return text.range(of: pattern, options: .regularExpression) != nil
    }
}
