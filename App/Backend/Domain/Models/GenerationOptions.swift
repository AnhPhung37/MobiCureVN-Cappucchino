import Foundation

/// How one request should be decoded — token ceiling and sampling — carried on `LLMRequest` so
/// each caller asks for what it actually needs.
///
/// Before this existed, `LLMService` hard-coded a single `GenerateParameters(maxTokens: 1024,
/// temperature: 0.3, topP: 0.85)` for *every* call. That is right for a medical answer and badly
/// wrong for everything else the app asks the model to do:
///
/// - `LanguageValidationService.detect` wants one word ("vietnamese"), and was given a
///   1024-token budget at answering temperature.
/// - `SessionFactExtractor` wants a short JSON array and was given the same.
/// - `LanguageValidationService.refine` wants a rewrite roughly the length of its input.
///
/// A token ceiling is not a cost by itself — generation stops at the EOS token either way — but
/// it is the only backstop when a small model *doesn't* stop: a classifier that starts explaining
/// itself runs to 1024 tokens, on the single serialized `ModelContainer`, with the user's next
/// message queued behind it. The sampling settings matter more directly: a classification or a
/// JSON extraction wants greedy, deterministic decoding, not the diversity that makes prose read
/// naturally.
///
/// Values come from `InferenceTuning`, so the ceilings are tunable without a rebuild.
nonisolated struct GenerationOptions: Sendable, Equatable {
    let maxTokens: Int
    let temperature: Float
    let topP: Float

    init(maxTokens: Int, temperature: Float, topP: Float) {
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
    }

    // MARK: - Presets

    /// A medical answer for the user: the full token budget, and the mildly-constrained sampling
    /// the chat pipeline was tuned around. Higher temperature/topP let the small multilingual
    /// model drift into English/Chinese/Thai mid-reply, which is why these are not library
    /// defaults.
    static var answer: GenerationOptions {
        let generation = InferenceTuning.current.generation
        return GenerationOptions(
            maxTokens: generation.maxTokens,
            temperature: generation.temperature,
            topP: generation.topP
        )
    }

    /// A single-word verdict ("vietnamese" / "english" / "other", "yes" / "no").
    ///
    /// Greedy: there is exactly one right answer and no reason to sample around it — sampling a
    /// classifier only adds a chance of the wrong label. The ceiling is deliberately generous
    /// rather than minimal, because Qwen-3-class models can emit a `<think>` preamble even with
    /// thinking disabled, and `stripThinking` needs the closing tag to be present to strip it.
    static var classification: GenerationOptions {
        GenerationOptions(
            maxTokens: InferenceTuning.current.generation.auxiliaryMaxTokens,
            temperature: 0,
            topP: 1
        )
    }

    /// A short structured payload — the session-fact JSON array. Greedy for the same reason as
    /// `classification`, and because malformed JSON is parsed as "no facts", so creative decoding
    /// here silently loses patient details rather than producing an interesting result.
    static var extraction: GenerationOptions {
        GenerationOptions(
            maxTokens: InferenceTuning.current.generation.auxiliaryMaxTokens * 4,
            temperature: 0,
            topP: 1
        )
    }

    /// A rewrite of the user's own text (typo/code-switch cleanup). Near-greedy: this must
    /// reproduce what the patient said with the spelling fixed, not paraphrase it.
    ///
    /// - Parameter inputLength: character count of the text being rewritten. The ceiling scales
    ///   with it — a rewrite is about as long as its input, and a fixed ceiling would either
    ///   truncate a long message or leave a runaway rewrite unbounded.
    static func rewrite(inputLength: Int) -> GenerationOptions {
        // ~1 token per 3 characters for Vietnamese/English prose, doubled for headroom, and never
        // below the auxiliary floor so a very short message still has room to be corrected.
        let estimate = (inputLength / 3) * 2
        let floor = InferenceTuning.current.generation.auxiliaryMaxTokens
        return GenerationOptions(
            maxTokens: max(estimate, floor),
            temperature: 0.1,
            topP: 1
        )
    }

    /// Visual findings from a wound photo, emitted as a fixed set of `KEY: value` lines that
    /// `WoundFindingsParser` reads positionally. Low temperature because the key set is a
    /// contract: a model that decides to rename or reorder a key produces an entry with empty
    /// fields, not a differently-worded one.
    static var structuredDescription: GenerationOptions {
        GenerationOptions(
            maxTokens: InferenceTuning.current.generation.maxTokens,
            temperature: 0.1,
            topP: 1
        )
    }
}
