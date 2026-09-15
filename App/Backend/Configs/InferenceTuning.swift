import CryptoKit
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
        /// that only ever need a few tokens; `GenerationOptions` derives the classification and
        /// extraction presets from it.
        let auxiliaryMaxTokens: Int

        /// KV-cache quantization and prefill controls.
        ///
        /// Applied by `LLMService` when set; `nil` keeps the mlx-swift-lm default (prefill step
        /// 512, no KV quantization, unbounded cache). Verified against the pinned 3.31.3 source in
        /// `Docs/BE/mlxApiVerification.md`, including two limits: `kvBits` has no effect together
        /// with `maxKVSize` (LLMService drops it and logs), and it quantizes only full-attention
        /// layers.
        let kvBits: Int?
        let kvGroupSize: Int?
        let quantizedKVStart: Int?
        let maxKVSize: Int?
        let prefillStepSize: Int?
    }

    /// Prompt assembly budgets. All token figures are *estimated* tokens — see
    /// `wordsToTokensRatio`.
    struct Prompt: Sendable {
        /// How many chunks retrieval returns for the prompt builder to pack.
        ///
        /// Coupled to `contextTokenBudget`, not independent of it. Measured over the golden set
        /// with the two-pass packer at Qwen 3.5's ratio, doc-hit of what the model sees: topK 5 at
        /// budget 2000 → 0.7416; topK 10 at 2000 → 0.7512; topK 10 at 3000 → 0.8134. Past five
        /// chunks the budget, not topK, decides how much of the extra retrieval reaches the model,
        /// so raise the two together. See Docs/BE/Context-Budget-Finding.md.
        let retrievalTopK: Int
        /// Token budget for retrieved RAG chunks injected into the system prompt.
        let contextTokenBudget: Int
        /// Token budget for replayed conversation history.
        let historyTokenBudget: Int
        /// Word cap applied to an assistant turn before it is replayed to the model.
        let assistantReplayWordCap: Int

        /// Override for the multiplier converting a cheap whitespace word count into a token
        /// estimate (checklist item B2.6).
        ///
        /// `nil`, the shipped value, means "use the measured ratio of the model that is actually
        /// answering" — `ModelCatalog.wordsToTokensRatio`. The budgets above exist to bound
        /// prefill on the chat model, and tokens per word differ materially between the shipped
        /// tokenizers (1.61 for Llama 3.2 against 2.04 for Phi-3.5 on this corpus), so a single
        /// global ratio either overshoots the budget on one model or starves the context on
        /// another. Set a number here only to pin a sweep to a fixed ratio, and sweep it together
        /// with the two budgets — they are one knob in two parts.
        let wordsToTokensRatio: Double?

        /// How many fused candidates the cross-encoder reranker scores before the best
        /// `retrievalTopK` are kept. `0` turns reranking off, and so does a build without
        /// `reranker.mlpackage` — retrieval then keeps the fused order. Each candidate is one
        /// 512-token prediction on the device, so this is the reranker's latency knob.
        ///
        /// Shipped at `0`: measured on the split index (Docs/BE/Reranker.md), ms-marco-MiniLM-L6
        /// raised recall@k at every candidate depth tried but LOWERED doc-hit@k (0.7799 → at best
        /// 0.7560 at k=5, 0.8756 → 0.8612 at k=10) — it reorders the right document's OTHER chunks
        /// ahead of chunks from a different, sometimes better, document more than it fixes wrong
        /// picks. Left in the catalog as an opt-in knob, not a default, until a reranker or a
        /// query set changes that trade-off.
        let rerankCandidates: Int
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

    /// The values the app ships with. `App/Resources/InferenceTuning.json` must resolve to
    /// exactly these (`InferenceTuningResolutionTests` fails when the two drift), so the
    /// bundled file and the compiled fallback can never describe two different apps.
    static let defaults = InferenceTuning(
        profileName: "built-in-defaults",
        generation: Generation(
            maxTokens: 512,
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
            retrievalTopK: 10,
            contextTokenBudget: 3000,
            historyTokenBudget: 350,
            assistantReplayWordCap: 60,
            wordsToTokensRatio: nil,
            rerankCandidates: 0
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

    /// Writes `configuration` to `Documents/InferenceTuning.json`, stamped with the fingerprint
    /// of its values, so there is always something concrete to edit on a device instead of an
    /// empty folder and a schema to guess at.
    ///
    /// Never overwrites a file someone may have edited: an existing file is replaced only when
    /// `replacingStaleSeed` says it is an untouched seed from an earlier build (see `layer`).
    /// Called automatically when `current` is resolved, so no launch-site wiring is needed.
    /// Failures are ignored: an unwritable Documents directory means no on-device tuning, not a
    /// broken app.
    @discardableResult
    static func seedDocumentsCopyIfMissing(
        from configuration: InferenceTuning,
        replacingStaleSeed: Bool = false
    ) -> Bool {
        guard let url = documentsURL else { return false }
        guard replacingStaleSeed || !FileManager.default.fileExists(atPath: url.path) else { return false }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            var seed = configuration.fileShape
            seed.profileName = "device-local (edit me, then relaunch)"
            seed.seedFingerprint = seed.valuesFingerprint
            try encoder.encode(seed).write(to: url, options: .atomic)
            log.info("seeded editable tuning file at \(url.path, privacy: .public)")
            return true
        } catch {
            log.error("could not seed tuning file — \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Loading

    /// Where the effective configuration came from.
    enum Source: Equatable, Sendable {
        case builtInDefaults
        case bundle
        /// A Documents file someone edited; the keys it sets override the bundle's.
        case documentsOverride
    }

    /// The resolution rule as a pure function, so it can be tested without a device.
    ///
    /// Layers, each overriding only the keys it sets: built-in defaults ← bundled JSON ←
    /// Documents JSON. A Documents file that is still exactly the seed some build wrote is NOT a
    /// layer — it records what that build resolved to, not a decision anyone made. Honouring it
    /// froze every later default on any device that had launched once: after the bundle moved
    /// `contextTokenBudget` from 600 to 2000, such a device kept running 600, and a key added
    /// later (`retrievalTopK`) combined with the stale values into a configuration nobody chose.
    ///
    /// - Returns: the configuration, its source, and whether the Documents file is an untouched
    ///   seed whose values no longer match what is running — the caller re-seeds it, so the file
    ///   on the device always shows the live values.
    static func layer(
        bundle: FileShape?,
        documents: FileShape?
    ) -> (tuning: InferenceTuning, source: Source, replaceStaleSeed: Bool) {
        let base = bundle?.resolved(over: defaults) ?? defaults
        let baseSource: Source = bundle == nil ? .builtInDefaults : .bundle
        guard let documents else { return (base, baseSource, false) }
        guard !documents.isUneditedSeed else {
            return (base, baseSource, documents.seedFingerprint != base.fileShape.valuesFingerprint)
        }
        return (documents.resolved(over: base), .documentsOverride, false)
    }

    private static func resolve() -> InferenceTuning {
        let bundleShape = Bundle.main
            .url(forResource: filename, withExtension: fileExtension)
            .flatMap(decodeShape(contentsOf:))
        let documentsShape = documentsURL.flatMap(decodeShape(contentsOf:))
        let (resolved, source, replaceStaleSeed) = layer(bundle: bundleShape, documents: documentsShape)

        switch source {
        case .documentsOverride:
            log.info("Documents file overrides the bundle — profile '\(resolved.profileName, privacy: .public)'")
        case .bundle:
            log.info("loaded from bundle — profile '\(resolved.profileName, privacy: .public)'")
        case .builtInDefaults:
            log.info("no tuning file found — using built-in defaults")
        }
        if replaceStaleSeed {
            log.info("Documents file was an unedited seed from an earlier build — replacing it")
        }
        resolved.logValues()

        // Seeding here (rather than from the app's `init`) keeps the whole mechanism inside this
        // one file — no launch-site wiring to forget. An existing file is replaced only when it
        // is an untouched seed that no longer matches; a malformed or edited file is left alone.
        if documentsShape == nil || replaceStaleSeed {
            seedDocumentsCopyIfMissing(from: resolved, replacingStaleSeed: replaceStaleSeed)
        }
        return resolved
    }

    private static func decodeShape(contentsOf url: URL) -> FileShape? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(FileShape.self, from: data)
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
            prompt(topK: \(prompt.retrievalTopK), context: \(prompt.contextTokenBudget), history: \(prompt.historyTokenBudget), ratio: \(prompt.wordsToTokensRatio.map { String($0) } ?? "per-model", privacy: .public), rerank: \(prompt.rerankCandidates)) \
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
        /// Fingerprint of the values this file held when the app wrote it as a seed. Present only
        /// on seeds, and equal to `valuesFingerprint` for as long as nobody edits the values.
        var seedFingerprint: String?

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
            var retrievalTopK: Int?
            var contextTokenBudget: Int?
            var historyTokenBudget: Int?
            var assistantReplayWordCap: Int?
            var wordsToTokensRatio: Double?
            var rerankCandidates: Int?
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

        /// SHA-256 of the values alone — `profileName` and `seedFingerprint` excluded — encoded
        /// with sorted keys, so it survives a decode/encode round trip unchanged.
        var valuesFingerprint: String {
            var values = self
            values.profileName = nil
            values.seedFingerprint = nil
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = (try? encoder.encode(values)) ?? Data()
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }

        /// A seed the app wrote that nobody has changed since. Renaming the profile alone is not
        /// an edit: the name is a label, not a value.
        var isUneditedSeed: Bool {
            guard let seedFingerprint else { return false }
            return seedFingerprint == valuesFingerprint
        }

        /// Merge over `base` — the built-in defaults, or the layer below this file — then clamp
        /// anything that would be nonsensical.
        func resolved(over base: InferenceTuning = InferenceTuning.defaults) -> InferenceTuning {
            let d = base

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
                retrievalTopK: max(1, self.prompt?.retrievalTopK ?? d.prompt.retrievalTopK),
                contextTokenBudget: max(0, self.prompt?.contextTokenBudget ?? d.prompt.contextTokenBudget),
                historyTokenBudget: max(0, self.prompt?.historyTokenBudget ?? d.prompt.historyTokenBudget),
                assistantReplayWordCap: max(1, self.prompt?.assistantReplayWordCap ?? d.prompt.assistantReplayWordCap),
                // Below 1.0 the "token" budgets would under-count words, which is the bug B2.6
                // fixed; refuse to reintroduce it through the config file. `nil` keeps the
                // measured per-model ratio.
                wordsToTokensRatio: (self.prompt?.wordsToTokensRatio ?? d.prompt.wordsToTokensRatio).map { max(1.0, $0) },
                // Each candidate is a full cross-encoder prediction; the ceiling keeps a typo from
                // turning retrieval into a multi-second stall.
                rerankCandidates: min(max(0, self.prompt?.rerankCandidates ?? d.prompt.rerankCandidates), 100)
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
                retrievalTopK: prompt.retrievalTopK,
                contextTokenBudget: prompt.contextTokenBudget,
                historyTokenBudget: prompt.historyTokenBudget,
                assistantReplayWordCap: prompt.assistantReplayWordCap,
                wordsToTokensRatio: prompt.wordsToTokensRatio,
                rerankCandidates: prompt.rerankCandidates
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
