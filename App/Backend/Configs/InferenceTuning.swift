import Foundation
import os

/// Every number that changes how the on-device model runs, in one place, loaded at launch from
/// a JSON file instead of being compiled in.
///
/// ## Why this exists
///
/// The inference constants used to live as `private static let`s across five files
/// (`LLMService`, `MedicalChatOrchestrator`, `UIImage+Attachment`, …). Tuning any of them meant
/// editing Swift, rebuilding, re-signing and re-deploying to a device — which makes an A/B
/// sweep ("does a 400-token context budget hurt answer quality?") cost minutes per data point
/// and makes it impossible for anyone without Xcode to run one. Performance work is a
/// measurement exercise; the knobs have to be cheaper to turn than that.
///
/// ## Where the values come from (first hit wins)
///
/// 1. `Documents/InferenceTuning.json` in the app's container — **the no-rebuild knob**. Edit
///    it, relaunch the app, and the new values are live. See `Docs/BE/inferenceTuning.md` for
///    how to get the file on and off a device.
/// 2. `InferenceTuning.json` bundled with the app — the defaults committed to the repo.
/// 3. The hard-coded defaults in this file — so a missing or corrupt file degrades to a
///    working app rather than a crash.
///
/// Resolution happens **once**, on first access, and the result is logged (source + profile
/// name + the values themselves) so a benchmark run always records which configuration
/// produced its numbers. A partial file is fine: any key you leave out keeps its default.
///
/// ## What this is not
///
/// Not a feature flag system, and not for anything a patient's safety depends on. Guardrail
/// rules stay in code/`GuardRailRules`, deliberately: a tuning file that can be edited on a
/// device must never be able to weaken a safety check.
nonisolated struct InferenceTuning: Sendable {

    /// Free-text label for the configuration, echoed into the launch log so a benchmark result
    /// can be traced back to the settings that produced it.
    let profileName: String

    let generation: Generation
    let prompt: Prompt
    let vision: Vision
    let memory: Memory

    // MARK: - Sections

    /// Sampling and decode limits handed to MLX's `GenerateParameters`.
    struct Generation: Sendable {
        /// Hard ceiling on tokens produced for a chat answer.
        let maxTokens: Int
        let temperature: Float
        let topP: Float

        /// Ceiling for the short auxiliary calls (language classification, fact extraction)
        /// that only ever need a few tokens. Not yet wired: `LLMRequest` currently has no way
        /// to carry per-call generation options, so every call shares `maxTokens` above.
        /// See Docs/BE/optimizationChecklist.md B1/3.1.
        let auxiliaryMaxTokens: Int

        /// KV-cache quantization and prefill controls.
        ///
        /// **Decoded but NOT yet applied.** The exact `GenerateParameters` field names for
        /// these differ between mlx-swift-lm versions, and this project has already been
        /// bitten once by reaching for the obvious-looking API and getting a deprecated one
        /// (`OOM-Memory-Management.md` §2.2). They are carried here so that the verification
        /// pass in `Docs/BE/mlxApiVerification.md` is a one-line wiring change per field
        /// rather than a re-design — and so they become tunable without a rebuild the moment
        /// that pass lands.
        let kvBits: Int?
        let kvGroupSize: Int?
        let quantizedKVStart: Int?
        let maxKVSize: Int?
        let prefillStepSize: Int?
    }

    /// Prompt assembly budgets. All token figures are *estimated* tokens — see
    /// `wordsToTokensRatio`.
    struct Prompt: Sendable {
        /// Token budget for retrieved RAG chunks injected into the system prompt.
        let contextTokenBudget: Int
        /// Token budget for replayed conversation history.
        let historyTokenBudget: Int
        /// Word cap applied to an assistant turn before it is replayed to the model.
        let assistantReplayWordCap: Int

        /// Multiplier converting a cheap whitespace word count into a token estimate.
        ///
        /// This is the knob behind checklist item B2.6. At `1.0` the budgets above behave
        /// exactly as they did historically (word counts wearing a token label, so the real
        /// prompt was ~40% larger than the number suggested). At `1.4` they mean roughly what
        /// they say for English medical prose. Sweep it together with the two budgets — they
        /// are one knob in two parts, and moving them independently will produce results that
        /// look contradictory.
        let wordsToTokensRatio: Double
    }

    /// Image handling on the way into a vision model.
    struct Vision: Sendable {
        /// Side length images are downscaled to before the vision tower sees them.
        let inputSide: Double
        /// How many past user turns may replay their photos into the prompt. `0` disables
        /// replay entirely (each photo is seen only on the turn it was sent); a large value
        /// restores the old unbounded behaviour. Dropped photos leave a text marker behind so
        /// the model still knows one existed.
        let historyImageTurnCap: Int
    }

    /// Memory ceilings for the MLX runtime.
    struct Memory: Sendable {
        /// Fraction of device RAM allowed for MLX's Metal buffer-reuse pool.
        let metalCacheFraction: Double
        let metalCacheFloorMB: Int
        let metalCacheCeilingMB: Int
        /// How many generated chunks the token stream may buffer when the UI falls behind.
        let tokenStreamBufferLimit: Int
    }

    // MARK: - Defaults

    /// The values the app ships with. Identical to the constants that used to be compiled into
    /// `LLMService` and `MedicalChatOrchestrator`, except `wordsToTokensRatio`, which was
    /// effectively `1.0` before checklist item B2.6.
    static let defaults = InferenceTuning(
        profileName: "built-in-defaults",
        generation: Generation(
            maxTokens: 1024,
            temperature: 0.3,
            topP: 0.85,
            auxiliaryMaxTokens: 64,
            kvBits: nil,
            kvGroupSize: nil,
            quantizedKVStart: nil,
            maxKVSize: nil,
            prefillStepSize: nil
        ),
        prompt: Prompt(
            contextTokenBudget: 600,
            historyTokenBudget: 500,
            assistantReplayWordCap: 60,
            wordsToTokensRatio: 1.4
        ),
        vision: Vision(
            inputSide: 512,
            historyImageTurnCap: 2
        ),
        memory: Memory(
            metalCacheFraction: 0.08,
            metalCacheFloorMB: 256,
            metalCacheCeilingMB: 1024,
            tokenStreamBufferLimit: 512
        )
    )

    // MARK: - Resolved configuration

    private static let log = Logger(subsystem: "MobiCureVN", category: "InferenceTuning")

    /// Filename looked up in both the Documents directory and the app bundle.
    static let filename = "InferenceTuning"
    static let fileExtension = "json"

    /// The configuration this run of the app is using. Resolved once, on first access.
    static let current: InferenceTuning = resolve()

    /// URL of the editable copy in the app's Documents directory, whether or not it exists yet.
    static var documentsURL: URL? {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("\(filename).\(fileExtension)")
    }

    /// Writes the currently-effective configuration to `Documents/InferenceTuning.json` if no
    /// file is there yet, so there is always something concrete to edit on a device instead of
    /// an empty folder and a schema to guess at. Never overwrites an existing file.
    ///
    /// Called automatically the first time `current` is resolved, so no launch-site wiring is
    /// needed anywhere else. Failures are ignored: an unwritable Documents directory means no
    /// on-device tuning, not a broken app.
    @discardableResult
    static func seedDocumentsCopyIfMissing(from configuration: InferenceTuning) -> Bool {
        guard let url = documentsURL else { return false }
        guard !FileManager.default.fileExists(atPath: url.path) else { return false }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            var seed = configuration.fileShape
            seed.profileName = "device-local (edit me, then relaunch)"
            try encoder.encode(seed).write(to: url, options: .atomic)
            log.info("seeded editable tuning file at \(url.path, privacy: .public)")
            return true
        } catch {
            log.error("could not seed tuning file — \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Loading

    private static func resolve() -> InferenceTuning {
        if let url = documentsURL, let loaded = decode(contentsOf: url) {
            log.info("loaded from Documents — profile '\(loaded.profileName, privacy: .public)'")
            loaded.logValues()
            return loaded
        }

        let fallback: InferenceTuning
        if let url = Bundle.main.url(forResource: filename, withExtension: fileExtension),
           let loaded = decode(contentsOf: url) {
            log.info("loaded from bundle — profile '\(loaded.profileName, privacy: .public)'")
            fallback = loaded
        } else {
            log.info("no tuning file found — using built-in defaults")
            fallback = defaults
        }

        fallback.logValues()
        // Nothing editable on the device yet: drop a copy of what we just resolved into
        // Documents so the next person to tune this has a real file to edit rather than a
        // schema to guess at. Seeding here (rather than from the app's `init`) keeps the whole
        // mechanism inside this one file — no launch-site wiring to forget.
        seedDocumentsCopyIfMissing(from: fallback)
        return fallback
    }

    private static func decode(contentsOf url: URL) -> InferenceTuning? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(FileShape.self, from: data).resolved()
        } catch {
            // A malformed file must never take the app down, and must never silently look like
            // it worked: log loudly and fall through to the next source.
            log.error("ignoring malformed tuning file at \(url.path, privacy: .public) — \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// One line per section, so a benchmark's console output carries the configuration that
    /// produced it. Deliberately not DEBUG-gated: this is metadata about the run, not user data.
    private func logValues() {
        Self.log.info("""
            generation(maxTokens: \(generation.maxTokens), temperature: \(generation.temperature), topP: \(generation.topP)) \
            prompt(context: \(prompt.contextTokenBudget), history: \(prompt.historyTokenBudget), ratio: \(prompt.wordsToTokensRatio)) \
            vision(side: \(vision.inputSide), historyImageTurns: \(vision.historyImageTurnCap)) \
            memory(cacheFraction: \(memory.metalCacheFraction), streamBuffer: \(memory.tokenStreamBufferLimit))
            """)
    }
}

// MARK: - Codable bridge

extension InferenceTuning {

    /// The on-disk shape: every field optional, so a tuning file may set one value and inherit
    /// the rest. Keeping this separate from the runtime type is what lets the runtime type have
    /// non-optional fields — call sites never deal with "what if this knob is missing".
    struct FileShape: Codable, Sendable {
        var profileName: String?

        var generation: GenerationFields?
        var prompt: PromptFields?
        var vision: VisionFields?
        var memory: MemoryFields?

        struct GenerationFields: Codable, Sendable {
            var maxTokens: Int?
            var temperature: Float?
            var topP: Float?
            var auxiliaryMaxTokens: Int?
            var kvBits: Int?
            var kvGroupSize: Int?
            var quantizedKVStart: Int?
            var maxKVSize: Int?
            var prefillStepSize: Int?
        }

        struct PromptFields: Codable, Sendable {
            var contextTokenBudget: Int?
            var historyTokenBudget: Int?
            var assistantReplayWordCap: Int?
            var wordsToTokensRatio: Double?
        }

        struct VisionFields: Codable, Sendable {
            var inputSide: Double?
            var historyImageTurnCap: Int?
        }

        struct MemoryFields: Codable, Sendable {
            var metalCacheFraction: Double?
            var metalCacheFloorMB: Int?
            var metalCacheCeilingMB: Int?
            var tokenStreamBufferLimit: Int?
        }

        /// Merge over the built-in defaults, then clamp anything that would be nonsensical.
        func resolved() -> InferenceTuning {
            let d = InferenceTuning.defaults

            let generation = InferenceTuning.Generation(
                maxTokens: max(1, self.generation?.maxTokens ?? d.generation.maxTokens),
                temperature: max(0, self.generation?.temperature ?? d.generation.temperature),
                topP: min(max(self.generation?.topP ?? d.generation.topP, 0.01), 1.0),
                auxiliaryMaxTokens: max(1, self.generation?.auxiliaryMaxTokens ?? d.generation.auxiliaryMaxTokens),
                kvBits: self.generation?.kvBits ?? d.generation.kvBits,
                kvGroupSize: self.generation?.kvGroupSize ?? d.generation.kvGroupSize,
                quantizedKVStart: self.generation?.quantizedKVStart ?? d.generation.quantizedKVStart,
                maxKVSize: self.generation?.maxKVSize ?? d.generation.maxKVSize,
                prefillStepSize: self.generation?.prefillStepSize ?? d.generation.prefillStepSize
            )

            let prompt = InferenceTuning.Prompt(
                contextTokenBudget: max(0, self.prompt?.contextTokenBudget ?? d.prompt.contextTokenBudget),
                historyTokenBudget: max(0, self.prompt?.historyTokenBudget ?? d.prompt.historyTokenBudget),
                assistantReplayWordCap: max(1, self.prompt?.assistantReplayWordCap ?? d.prompt.assistantReplayWordCap),
                // Below 1.0 the "token" budgets would under-count words, which is the bug B2.6
                // fixed; refuse to reintroduce it through the config file.
                wordsToTokensRatio: max(1.0, self.prompt?.wordsToTokensRatio ?? d.prompt.wordsToTokensRatio)
            )

            let vision = InferenceTuning.Vision(
                // 64px is below any sane vision patch grid; the ceiling keeps a typo from
                // turning one photo into a prefill that never finishes.
                inputSide: min(max(self.vision?.inputSide ?? d.vision.inputSide, 64), 2048),
                historyImageTurnCap: max(0, self.vision?.historyImageTurnCap ?? d.vision.historyImageTurnCap)
            )

            let memoryFloor = max(0, self.memory?.metalCacheFloorMB ?? d.memory.metalCacheFloorMB)
            let memory = InferenceTuning.Memory(
                metalCacheFraction: min(max(self.memory?.metalCacheFraction ?? d.memory.metalCacheFraction, 0.01), 0.5),
                metalCacheFloorMB: memoryFloor,
                metalCacheCeilingMB: max(memoryFloor, self.memory?.metalCacheCeilingMB ?? d.memory.metalCacheCeilingMB),
                tokenStreamBufferLimit: max(1, self.memory?.tokenStreamBufferLimit ?? d.memory.tokenStreamBufferLimit)
            )

            return InferenceTuning(
                profileName: profileName ?? d.profileName,
                generation: generation,
                prompt: prompt,
                vision: vision,
                memory: memory
            )
        }
    }

    /// Round-trip back to the on-disk shape, used to seed an editable copy on the device.
    var fileShape: FileShape {
        FileShape(
            profileName: profileName,
            generation: .init(
                maxTokens: generation.maxTokens,
                temperature: generation.temperature,
                topP: generation.topP,
                auxiliaryMaxTokens: generation.auxiliaryMaxTokens,
                kvBits: generation.kvBits,
                kvGroupSize: generation.kvGroupSize,
                quantizedKVStart: generation.quantizedKVStart,
                maxKVSize: generation.maxKVSize,
                prefillStepSize: generation.prefillStepSize
            ),
            prompt: .init(
                contextTokenBudget: prompt.contextTokenBudget,
                historyTokenBudget: prompt.historyTokenBudget,
                assistantReplayWordCap: prompt.assistantReplayWordCap,
                wordsToTokensRatio: prompt.wordsToTokensRatio
            ),
            vision: .init(
                inputSide: vision.inputSide,
                historyImageTurnCap: vision.historyImageTurnCap
            ),
            memory: .init(
                metalCacheFraction: memory.metalCacheFraction,
                metalCacheFloorMB: memory.metalCacheFloorMB,
                metalCacheCeilingMB: memory.metalCacheCeilingMB,
                tokenStreamBufferLimit: memory.tokenStreamBufferLimit
            )
        )
    }
}
