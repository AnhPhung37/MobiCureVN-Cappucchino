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

    // MARK: - Detection Tuning Constants

    // Vietnamese "density" is the fraction of a text's words that carry a Vietnamese
    // signal — either a Vietnamese-only diacritic or a common accent-less Vietnamese
    // function word (see `vietnameseFunctionWords`). It replaces the old boolean
    // "contains any diacritic" test, whose bias let a single accented word (e.g. an
    // English sentence mentioning "Đà Nẵng") force the whole turn to Vietnamese/mixed.
    //
    // At/above `vietnameseDensityThreshold` the text is treated as Vietnamese-dominant.
    // Set at 0.25 so a one- or two-word Vietnamese place name in a short English sentence
    // (e.g. "The clinic in Hà Nội gave me antibiotics" — 2/12 ≈ 0.17) stays below it and is
    // NOT promoted to .mixed, while genuine code-switching (a substantial run of Vietnamese
    // words) clears it. Tuned conservatively — revisit with real usage data.
    private static let vietnameseDensityThreshold = 0.25

    // Well above the threshold: DIACRITIC density this high is unambiguous Vietnamese, so
    // `detect` can short-circuit and skip the LLM round-trip entirely (latency win). We gate
    // the short-circuit on diacritic density specifically — NOT the function-word signal —
    // so accent-less Vietnamese ("toi bi dau bung"), whose diacritic density is zero, always
    // reaches the LLM. That's the whole point of having an LLM detector: the deterministic
    // signal can't safely resolve accent-less input on its own.
    private static let vietnameseConfidentDensityThreshold = 0.35

    // A deliberately low floor: any Vietnamese signal at all. Used ONLY to veto a spurious
    // "vietnamese" verdict from the small on-device classifier, which sometimes mislabels a
    // short plain-English sentence as Vietnamese. A pure-English sentence has density 0 and
    // is vetoed to .english; genuine Vietnamese — including accent-less input carrying one
    // function word — clears this and is trusted. Kept just above 0 to ignore float noise.
    private static let vietnameseMinSignalThreshold = 0.0001

    // Common Vietnamese function words that survive being typed without accents on a mobile
    // keyboard. Presence of these (as whole words) is a Vietnamese signal even with no
    // diacritic present. Deliberately EXCLUDES accent-less forms that collide with common
    // English words ("the", "la", "co", "me", "so", "an", "to") — those would falsely inflate
    // density on plain English sentences (the exact issue-#2 misrouting we're fixing). Every
    // entry here is a whole-word token that is overwhelmingly Vietnamese in this app's domain.
    private static let vietnameseFunctionWords: Set<String> = [
        "toi", "khong", "duoc", "bi", "dau", "va", "cua", "voi", "gi",
        "nao", "cho", "khi", "roi", "nhung", "cung", "minh"
    ]

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

    /// Classifies `text` as Vietnamese/English/unsupported. Detection is text-only and
    /// ChatGPT-style: the app's VI/EN display toggle (AppLanguage) MUST NOT influence it.
    ///
    /// Two-tier strategy for latency:
    ///   • Deterministic short-circuit — if Vietnamese density is clearly high, or a foreign
    ///     script is present, we answer without an LLM round-trip.
    ///   • LLM classifier — only for the genuinely ambiguous middle. This is why the LLM
    ///     detector still exists: accent-less Vietnamese ("toi bi dau bung") has low density
    ///     yet must be caught, and the LLM handles it where NLLanguageRecognizer (which
    ///     misreads such strings as Romanian/Polish) does not.
    func detect(_ text: String, using llmService: LLMServiceProtocol) async -> DetectedLanguage {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .english }

        let density = vietnameseDensity(trimmed)

        // Short-circuit 1: a non-Vietnamese/English script present means we don't need the
        // LLM to know this is unsupported. (Vietnamese uses Latin script, so any Han/Kana/
        // Hangul/Thai run is a foreign language, not code-switching we translate.)
        if containsForeignScript(trimmed) {
            return .unsupported(detected: "foreign-script")
        }

        // Short-circuit 2: unambiguously diacritic-dense text skips the LLM entirely.
        // Gated on diacritic density (not the overall signal) so accent-less Vietnamese,
        // which has zero diacritic density, still falls through to the LLM below.
        if vietnameseDiacriticDensity(trimmed) >= Self.vietnameseConfidentDensityThreshold {
            return .vietnamese
        }

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
        let normalized = Self.stripThinking(reply)
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        print("LanguageValidation: detect reply='\(normalized.prefix(200))'")

        let isVietnameseDominant = density >= Self.vietnameseDensityThreshold
        // A far lower bar than dominance: is there ANY Vietnamese signal at all? Used only to
        // sanity-check a "vietnamese" verdict from the LLM — a pure-English sentence has zero
        // signal and must not be trusted as Vietnamese, but genuine Vietnamese (even a single
        // accent-less function word like "toi") clears this. See the `vietnamese` branch below.
        let hasVietnameseSignal = density >= Self.vietnameseMinSignalThreshold

        // A failed or empty generation is a runtime problem, not a language problem —
        // fail open so the pipeline continues and the real error (e.g. "[MLX error: …]")
        // surfaces in chat instead of the misleading unsupported-language refusal. Use the
        // density signal to pick the language rather than any single diacritic.
        if normalized.isEmpty || normalized.hasPrefix("[mlx error") {
            return isVietnameseDominant ? .vietnamese : .english
        }

        if normalized.contains("vietnamese") {
            // Guard against the small on-device classifier mislabelling a plain-English
            // sentence as "vietnamese" (it does this on short strings). Real Vietnamese —
            // even typed without accents — carries at least some Vietnamese signal, so a
            // text with essentially zero Vietnamese density is overridden to English.
            // This is the mirror of the English→mixed density gate below; without it the
            // Vietnamese branch had no counter-check and silently mis-routed English turns.
            return hasVietnameseSignal ? .vietnamese : .english
        }
        if normalized.contains("english") {
            // Only promote English → mixed when Vietnamese density clears the threshold.
            // A single accented word (e.g. a place name) no longer misroutes the whole
            // turn into the translate path; that was issue #2.
            return isVietnameseDominant ? .mixed : .english
        }
        return hasVietnameseSignal ? .vietnamese : .unsupported(detected: normalized)
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
    ///
    /// This verify path deliberately trades latency for translation-correctness robustness:
    /// it can make up to two LLM calls to break a tie. A wrong verdict here ships a response
    /// in the wrong language to the user, so the extra round-trip is worth it.
    ///
    ///   Pass 0 (deterministic pre-filter): a leaked foreign script fails immediately;
    ///           Vietnamese density gives a provisional verdict, no LLM.
    ///   Pass 1 (LLM classify): classify the translated text's language.
    ///   Pass 2 (LLM confirm): only when Pass 0 and Pass 1 disagree, or the density is
    ///           borderline, ask a second targeted yes/no question to break the tie.
    func matches(_ text: String, expected: DetectedLanguage, using llmService: LLMServiceProtocol) async -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }

        let expectsVietnamese = expected.requiresTranslation

        // Pass 0 — deterministic pre-filter.
        // A leaked CJK/Thai word fails outright, even when the LLM classifier would still
        // call the overall paragraph correct.
        if containsForeignScript(text) { return false }
        let density = vietnameseDensity(text)
        let provisionalIsVietnamese = density >= Self.vietnameseDensityThreshold
        // "Borderline" = density sits near the threshold, where the deterministic signal is
        // least trustworthy and a confirm pass is most valuable.
        let borderline = abs(density - Self.vietnameseDensityThreshold) < 0.10

        // Pass 1 — LLM classify.
        let detected = await detect(text, using: llmService)
        let pass1IsVietnamese = detected == .vietnamese || detected == .mixed

        // Agreement between Pass 0 and Pass 1, and not borderline: trust it, no Pass 2.
        if pass1IsVietnamese == provisionalIsVietnamese && !borderline {
            return pass1IsVietnamese == expectsVietnamese
        }

        // Pass 2 — LLM confirm. Disagreement or borderline: ask a targeted yes/no about the
        // language we expect, and let that break the tie.
        let confirmedVietnamese = await confirmLanguage(
            text, isVietnamese: expectsVietnamese, using: llmService
        )
        return confirmedVietnamese == expectsVietnamese
    }

    /// Second-pass targeted confirmation for `matches`. Asks the LLM a single yes/no
    /// question — "Is this text written in {Vietnamese|English}?" — which is an easier
    /// judgement for a small model than open classification, so it breaks ties reliably.
    /// Returns whether the text is Vietnamese. Fails open toward the deterministic density
    /// signal when the model returns empty/error, so a runtime failure never flips a verdict.
    private func confirmLanguage(
        _ text: String,
        isVietnamese expectVietnamese: Bool,
        using llmService: LLMServiceProtocol
    ) async -> Bool {
        let languageName = expectVietnamese ? "Vietnamese" : "English"
        let prompt = """
        Is the TEXT below written in \(languageName)? Reply with exactly one word — \
        "yes" or "no" — and nothing else. Do not answer or explain the text.

        TEXT: \(text)
        """

        let stream = llmService.stream(request: LLMRequest(userMessage: prompt))
        var reply = ""
        for await token in stream {
            reply += token
        }
        let normalized = Self.stripThinking(reply)
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // Fail open to the deterministic density signal on empty/error replies.
        if normalized.isEmpty || normalized.hasPrefix("[mlx error") {
            return vietnameseDensity(text) >= Self.vietnameseDensityThreshold
        }

        // "yes" confirms the language we asked about; "no" denies it.
        if normalized.hasPrefix("yes") { return expectVietnamese }
        if normalized.hasPrefix("no") { return !expectVietnamese }
        // Ambiguous reply: fall back to the density signal.
        return vietnameseDensity(text) >= Self.vietnameseDensityThreshold
    }

    /// Translates `text` into `targetLanguage` via the LLM. Primary path for converting the
    /// English response back to the user's language: the LLM produces a noticeably more
    /// natural, conversational tone than Apple's fairly literal Translation framework.
    /// The trade-off is that a small on-device model can leak stray foreign-script words or
    /// truncate long inputs, so callers MUST verify the result with `matches` (plus a length
    /// sanity check) and fall back to Apple's Translation framework when verification fails.
    func translate(
        _ text: String,
        to targetLanguage: DetectedLanguage,
        using llmService: LLMServiceProtocol
    ) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        let targetName = targetLanguage.requiresTranslation ? "Vietnamese" : "English"
        let prompt = """
        Translate the TEXT below into natural, conversational \(targetName), phrased the way \
        a friendly medical assistant would say it. Keep every medical fact, term, and number \
        accurate. Do NOT use any other language in your translation. Reply with ONLY the \
        translated text, nothing else.

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

    // Removes a `<think>…</think>` reasoning preamble that Qwen 3-class models can emit
    // even with enable_thinking off, so classification sees only the final answer. An
    // unterminated block strips to empty, which routes into detect's fail-open path.
    private static func stripThinking(_ reply: String) -> String {
        reply.replacingOccurrences(
            of: "(?s)<think>.*?(</think>|$)",
            with: "",
            options: .regularExpression
        )
    }

    // Characters that appear only in Vietnamese (tone marks + ă, đ, ơ, ư and their
    // combining forms), lower-cased for whole-set membership tests.
    private static let vietnameseDiacriticChars = Set(
        "àáâãèéêìíòóôõùúý" +
        "ăđơư" +
        "ạảấầẩẫậắằẳẵặẹẻẽếềểễệỉịọỏốồổỗộớờởỡợụủứừửữựỳỵỷỹ"
    )

    /// Fraction of words carrying a Vietnamese signal — either a Vietnamese-only diacritic,
    /// or membership in `vietnameseFunctionWords` (accent-less). Range 0…1.
    ///
    /// Density, not a boolean "contains any diacritic", is what distinguishes a genuinely
    /// Vietnamese/code-switched turn from an English sentence that merely mentions one
    /// accented word (a place name, a borrowed term): a single accented word in a long
    /// English sentence produces a tiny ratio well below `vietnameseDensityThreshold`.
    func vietnameseDensity(_ text: String) -> Double {
        let words = Self.words(in: text)
        guard !words.isEmpty else { return 0 }

        let vietnameseWords = words.filter { word in
            word.contains(where: { Self.vietnameseDiacriticChars.contains($0) })
                || Self.vietnameseFunctionWords.contains(word)
        }
        return Double(vietnameseWords.count) / Double(words.count)
    }

    /// Fraction of words carrying an actual Vietnamese diacritic (function words excluded).
    /// Used only for the confident short-circuit in `detect`: accent-less Vietnamese has a
    /// diacritic density of zero and so is deliberately routed to the LLM rather than
    /// resolved deterministically.
    private func vietnameseDiacriticDensity(_ text: String) -> Double {
        let words = Self.words(in: text)
        guard !words.isEmpty else { return 0 }

        let diacriticWords = words.filter { word in
            word.contains(where: { Self.vietnameseDiacriticChars.contains($0) })
        }
        return Double(diacriticWords.count) / Double(words.count)
    }

    // Splits `text` into lower-cased word tokens, treating Vietnamese diacritic characters
    // as letters so accented words aren't fragmented at the accent.
    private static func words(in text: String) -> [String] {
        text
            .lowercased()
            .split { !$0.isLetter && !vietnameseDiacriticChars.contains($0) }
            .map(String.init)
    }
}
