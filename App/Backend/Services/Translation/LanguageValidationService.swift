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

    // How many common-English words in a row mark an untranslated fragment in Vietnamese
    // output. Two is the smallest run that reliably signals a leaked clause ("I'm sorry",
    // "so much") while letting a single loanword/brand/proper-noun pass. See
    // `containsEnglishLeak`.
    private static let englishLeakRunLength = 2

    // High-frequency English function/filler words used to spot untranslated English runs in
    // Vietnamese output. Deliberately excludes words that collide with valid accent-less
    // Vietnamese tokens (e.g. "toi", "co", "la", "an") so genuine Vietnamese never registers as
    // an English run. These are the words a small model is most likely to leave untranslated
    // mid-sentence; medical nouns are omitted on purpose (a lone noun shouldn't trip the run).
    private static let commonEnglishWords: Set<String> = [
        "i", "im", "you", "your", "we", "they", "he", "she", "it", "is", "are", "was",
        "were", "be", "been", "am", "the", "and", "but", "or", "if", "not", "no", "yes",
        "do", "does", "did", "have", "has", "had", "will", "would", "should", "could",
        "can", "may", "must", "sorry", "please", "thank", "thanks", "hello", "hi",
        "sure", "okay", "ok", "very", "much", "more", "some", "any", "all", "with",
        "for", "from", "this", "that", "these", "those", "here", "there", "what", "when",
        "where", "which", "how", "why", "who", "about", "after", "before", "because",
        "of", "to", "in", "on", "at", "by", "as", "so", "just", "now", "then", "still",
        "help", "feel", "feeling", "hear", "sounds", "like", "please", "consult"
    ]

    // MARK: - Generated-output language check

    /// Outcome of checking that a generated response actually came out in the language the
    /// model was asked to write in.
    enum OutputLanguageCheck: Equatable {
        /// The response is in the expected language.
        case ok
        /// A non-Vietnamese/English script (CJK, Thai, …) leaked into the response.
        case foreignScript
        /// The response is in the wrong language outright — asked for Vietnamese, wrote English.
        case wrongLanguage
        /// Predominantly the right language, but a run of untranslated English leaked through.
        case codeSwitched

        var reason: String {
            switch self {
            case .ok:            return "ok"
            case .foreignScript: return "foreign-script leak"
            case .wrongLanguage: return "wrong language"
            case .codeSwitched:  return "code-switch leak"
            }
        }
    }

    /// Verifies a generated response is in `expected`. Purely deterministic — script scan plus
    /// Vietnamese density plus English-run detection — so it costs no LLM time.
    ///
    /// This replaces the old LLM verification pass that ran after translating an English answer
    /// into Vietnamese. Now that the model writes Vietnamese directly, the only failure worth
    /// catching is drift: a small model told to answer in Vietnamese can slip back into English,
    /// usually because the retrieved medical context it is drawing on is English. Density
    /// separates that case cleanly — a genuine Vietnamese answer sits far above the threshold,
    /// an English one sits at essentially zero — and no model round-trip is needed to see it.
    func checkGeneratedLanguage(_ text: String, expected: DetectedLanguage) -> OutputLanguageCheck {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .ok }

        if containsForeignScript(trimmed) { return .foreignScript }

        let density = vietnameseDensity(trimmed)
        guard expected.requiresTranslation else {
            // Expected English: a Vietnamese-dominant answer means the model ignored the
            // instruction. Anything below the dominance bar is treated as fine, since English
            // answers legitimately mention Vietnamese place names and terms.
            return density >= Self.vietnameseDensityThreshold ? .wrongLanguage : .ok
        }

        guard density >= Self.vietnameseDensityThreshold else { return .wrongLanguage }
        return containsEnglishLeak(trimmed) ? .codeSwitched : .ok
    }

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

    /// Detects English *leaking* into text that should be pure Vietnamese — the code-switch
    /// failure seen as "Tôi sorry, tôi rất tiếc…", where a small model translated most of a
    /// sentence but left an English word (or clause) untranslated. `containsForeignScript`
    /// cannot catch this: English is Latin script, exactly like Vietnamese.
    ///
    /// The signal is a RUN of consecutive common-English words, not any single one. A lone
    /// English token in Vietnamese is usually a legitimate loanword, brand, or proper noun
    /// ("app", "email", a drug name) and must NOT trigger a fallback; but two or more common
    /// English words in a row are almost always an untranslated fragment. This is the tolerant
    /// "flag runs" policy — it caught the observed leak without over-firing on borrowed terms.
    ///
    /// A word counts as English only if it's in `commonEnglishWords` AND carries no Vietnamese
    /// diacritic, so Vietnamese words that happen to share a spelling are never miscounted.
    func containsEnglishLeak(_ text: String) -> Bool {
        let words = Self.words(in: text)
        guard words.count >= Self.englishLeakRunLength else { return false }

        var run = 0
        for word in words {
            let isEnglish = Self.commonEnglishWords.contains(word)
                && !word.contains(where: { Self.vietnameseDiacriticChars.contains($0) })
            if isEnglish {
                run += 1
                if run >= Self.englishLeakRunLength { return true }
            } else {
                run = 0
            }
        }
        return false
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

        // One word is the whole expected output; `.classification` is greedy and capped
        // accordingly instead of inheriting a 1024-token answering budget.
        let stream = llmService.stream(request: LLMRequest(
            userMessage: prompt,
            options: .classification
        ))
        var reply = ""
        for await token in stream {
            reply += token
        }
        let normalized = Self.stripThinking(reply)
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // DEBUG-only: this echoes model output derived from the patient's own message, and a
        // release build has no business writing that to the device log. Same rule ChatFlowLog
        // already applies to itself.
        #if DEBUG
        print("LanguageValidation: detect reply='\(normalized.prefix(200))'")
        #endif

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

    /// Whether `text` is messy enough to be worth an LLM refine pass.
    ///
    /// Refine is a full LLM round-trip charged to every single turn, and for most inputs it
    /// returns the text essentially unchanged — Apple's Translation framework already copes
    /// with ordinary typos, and clean Vietnamese or clean English needs no unification. Gating
    /// it on the two cases where it demonstrably earns its cost removes that round-trip from
    /// the majority of turns:
    ///
    ///   1. Code-switching — Vietnamese text carrying a run of English words. Unifying it into
    ///      one language before translation is exactly what refine is for.
    ///   2. Accent-less Vietnamese ("toi bi dau bung") — Vietnamese signal present but zero
    ///      diacritics, i.e. typed without tone marks. Restoring the accents materially
    ///      improves what Apple Translation produces downstream.
    ///
    /// Everything else — clean accented Vietnamese, plain English, very short fragments —
    /// skips the pass. English typos are no longer corrected up front; the model handles them
    /// in context, and an English turn never goes through translation anyway.
    ///
    /// KNOWN BLIND SPOT: badly-mangled telex ("Tui themf traf suxwa" for "Tôi thèm trà sữa")
    /// has no diacritics AND no recognisable function words, so its density is 0 and the guard
    /// below reads it as plain English — skipping the very input refine exists to fix. Rather
    /// than keep widening the deterministic signal to catch every mangling, callers recover on
    /// the rejection path: see `refine(_:using:force:)` and ChatService's unsupported branch.
    func needsRefinement(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = Self.words(in: trimmed)
        // Too short to have structure worth fixing, and the shortest inputs are where a
        // refine pass is most likely to hallucinate a rewrite rather than correct one.
        guard words.count >= 3 else { return false }

        guard vietnameseDensity(trimmed) >= Self.vietnameseMinSignalThreshold else {
            // No Vietnamese signal at all: plain English. Nothing to unify.
            return false
        }

        // Case 1: Vietnamese carrying an untranslated English run.
        if containsEnglishLeak(trimmed) { return true }

        // Case 2: Vietnamese signal came entirely from accent-less function words.
        return vietnameseDiacriticDensity(trimmed) == 0
    }

    /// Asks the LLM to clean up the user's raw input — fix typos, unify Vietnamese/English
    /// code-switching into one language, tidy grammar — while strictly preserving the
    /// original language and meaning. This runs before translation so Apple's Translation
    /// framework receives a clean, single-language source string instead of a typo-ridden
    /// or code-switched one.
    ///
    /// Gated by `needsRefinement`: most turns are already clean and return immediately without
    /// touching the LLM.
    ///
    /// - Parameter force: bypasses the gate and always runs the pass. Reserved for the recovery
    ///   path taken when detection has already come back unsupported — at that point the turn is
    ///   about to be refused outright, so one extra round-trip is cheap insurance against the
    ///   gate's blind spot (see `needsRefinement`). Never set this on the happy path; doing so
    ///   puts the LLM round-trip back on every turn, which is what the gate removed.
    func refine(
        _ text: String,
        using llmService: LLMServiceProtocol,
        force: Bool = false
    ) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        guard force || needsRefinement(trimmed) else {
            #if DEBUG
            print("LanguageValidation: refine skipped (input already clean)")
            #endif
            return text
        }

        let prompt = """
        Rewrite the TEXT below to fix typos, spelling, and grammar, and if it mixes two \
        languages, unify it into a single language (prefer the dominant one). \
        Do NOT translate it into a different language. Do NOT answer the text or add \
        any commentary. Reply with ONLY the corrected text, nothing else.

        TEXT: \(trimmed)
        """

        // A rewrite is about as long as its input, so the ceiling scales with it rather than
        // sitting at the answering budget.
        let stream = llmService.stream(request: LLMRequest(
            userMessage: prompt,
            options: .rewrite(inputLength: trimmed.count)
        ))
        var reply = ""
        for await token in stream {
            reply += token
        }
        let corrected = reply.trimmingCharacters(in: .whitespacesAndNewlines)

        // DEBUG-only: `trimmed` is the patient's raw message.
        #if DEBUG
        print("LanguageValidation: refine in='\(trimmed)' out='\(corrected)'")
        #endif

        // Guard against a degenerate refine (empty, or so much shorter it likely dropped
        // content) — fall back to the original text rather than lose meaning.
        guard !corrected.isEmpty, corrected.count > trimmed.count / 2 else { return text }
        return corrected
    }

    // NOTE: `matches`, `confirmLanguage` and `translate` used to live here — an LLM-based
    // output-language verifier (up to two round-trips) plus an LLM translator. Both became
    // unreachable when generation went native: the answer is now written directly in the
    // user's language and verified by the deterministic `checkGeneratedLanguage` above, with
    // Apple Translation as the only repair path. They were removed rather than left compiled
    // in — see Docs/BE/optimizationChecklist.md B4.1. `stripThinking` below is still used by
    // `detect`.

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
