import Foundation
import os

#if canImport(MLXLLM)
import CoreImage
import MLX
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers
#endif
#if canImport(MLXVLM)
import MLXVLM
#endif

nonisolated final class LLMService: @unchecked Sendable, LLMServiceProtocol {

    // MARK: - Tuning

    /// All runtime knobs come from `InferenceTuning`, which loads them from a JSON file at
    /// launch (Documents copy → bundled default → built-in constants). They are read through
    /// these accessors rather than inline so there is exactly one name per knob in this file,
    /// and so a benchmark sweep needs no rebuild. See `Docs/BE/inferenceTuning.md`.
    private static var tuning: InferenceTuning { InferenceTuning.current }

    /// Side length images are downscaled to before they reach the vision tower. A
    /// full-resolution photo expands into thousands of image tokens on a small VLM; the default
    /// 512px is ample for wound / medication-label photos and keeps prefill in the seconds
    /// range. `UIImage+Attachment` sizes its JPEGs against this — anything larger is bytes the
    /// model never sees.
    static var visionInputSide: Double { tuning.vision.inputSide }

    /// How many past user turns may replay their images into the prompt. Each replayed image
    /// is re-encoded by the vision tower on every subsequent turn and is invisible to
    /// `MedicalChatOrchestrator`'s history token budget (which meters text only), so an
    /// image-heavy conversation would otherwise grow its own prefill cost without bound.
    /// The current turn's images are always attached and are not counted here.
    private static var historyImageTurnCap: Int { tuning.vision.historyImageTurnCap }

    /// Bounded so a consumer that falls behind cannot accumulate an entire response in RAM.
    /// The UI has already rendered anything old enough to be evicted; only the internal
    /// replay buffer is bounded, never what the user sees. See OOM-Memory-Management.md §2.1.
    private static var tokenBufferLimit: Int { tuning.memory.tokenStreamBufferLimit }

    private static let log = Logger(subsystem: "MobiCureVN", category: "LLMService")

    private let modelPath: String
    private let useMock: Bool
    private let isModelAvailable: Bool
    private var mlxInitialized: Bool = false
    // Guards mlxInitialized/modelContainer: written by initializeModel and read by the
    // detached generation task, potentially on different threads. OSAllocatedUnfairLock
    // (unlike NSLock) is safe to call from async contexts under Swift 6 strict concurrency.
    private let stateLock = OSAllocatedUnfairLock()
#if canImport(MLXLLM)
    private var modelContainer: ModelContainer?
#endif

    /// Whether the local model is a vision-language model (accepts images). Decided once
    /// from config.json's `model_type` so loading can route through VLMModelFactory and
    /// generation knows whether attaching images is meaningful.
    let isVisionModel: Bool

    /// `config.json`'s `model_type`, lowercased. Prefix-cache resumption is verified per
    /// architecture (`PrefixCachePlanner.resumableModelTypes`).
    let modelType: String?

    /// `nil` follows `InferenceTuning.generation.prefixCache`; the device check pins it per instance.
    private let prefixCacheOverride: Bool?

    // Prefix KV cache state, guarded by `stateLock`. See Docs/BE/Prefix-KV-Cache.md.
#if canImport(MLXLLM)
    private var prefixSnapshot: PrefixSnapshot?
#endif
    private var previousPromptTokens: [Int]?
    private var lastGenerationHadMedia = false
    private var prefixStats = PrefixCacheStats()

    init(modelPath: String = "qwen-2.5-7b-instruct", useMock: Bool = false, prefixCache: Bool? = nil) {
        self.modelPath = modelPath
        self.useMock = useMock
        self.isModelAvailable = FileManager.default.fileExists(atPath: modelPath)
        let modelType = Self.readModelType(at: modelPath)
        self.modelType = modelType
        self.isVisionModel = modelType.map { Self.visionModelTypes.contains($0) } ?? false
        self.prefixCacheOverride = prefixCache
    }

    /// model_type values registered by MLXVLM's VLMModelFactory (mlx-swift-lm 3.31.3,
    /// VLMModelFactory.swift). Text-only exports use distinct types (e.g. Gemma 3's
    /// text-only repos are "gemma3_text"), so this set is safe to match exactly.
    private static let visionModelTypes: Set<String> = [
        "fastvlm", "gemma3", "gemma4", "glm_ocr", "idefics3", "lfm2_vl", "llava_qwen2",
        "mistral3", "paligemma", "pixtral", "qwen2_vl", "qwen2_5_vl", "qwen3_vl",
        "qwen3_5", "qwen3_5_moe", "smolvlm"
    ]

    private static func readModelType(at path: String) -> String? {
        let configURL = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let modelType = json["model_type"] as? String else {
            return nil
        }
        return modelType.lowercased()
    }

    func initializeModel() async -> Bool {
        guard !useMock else {
            Self.log.debug("useMock=true, skipping MLX init")
            return false
        }
        guard isModelAvailable else {
            Self.log.error("model path not found: \(self.modelPath, privacy: .public)")
            return false
        }
#if canImport(MLXLLM)
        do {
            let modelURL = URL(fileURLWithPath: modelPath, isDirectory: true)
            let container: ModelContainer
#if canImport(MLXVLM)
            if isVisionModel {
                // Vision-language models (image tower + projector) only load through
                // VLMModelFactory; LLMModelFactory doesn't know their model_type.
                container = try await VLMModelFactory.shared.loadContainer(
                    from: modelURL,
                    using: #huggingFaceTokenizerLoader()
                )
            } else {
                container = try await LLMModelFactory.shared.loadContainer(
                    from: modelURL,
                    using: #huggingFaceTokenizerLoader()
                )
            }
#else
            container = try await LLMModelFactory.shared.loadContainer(
                from: modelURL,
                using: #huggingFaceTokenizerLoader()
            )
#endif
            stateLock.withLock {
                modelContainer = container
                mlxInitialized = true
            }
            // Cap Metal's buffer-reuse cache so it doesn't compete unbounded with the
            // OS memory budget on iOS (jetsam will kill the app past its RAM limit). Scaled
            // to the device rather than fixed: the same constant is wasteful on an 8 GB phone
            // and marginal on a 4 GB one.
            MLX.Memory.cacheLimit = Self.deviceScaledCacheLimit()
            // Pay the lazy Metal kernel compilation now, while the UI is still showing model
            // setup, instead of adding it to the first message's time-to-first-token.
            await Self.warmUp(container)
            Self.log.info("MLX initialized at \(self.modelPath, privacy: .public)")
            return true
        } catch {
            Self.log.error("MLX initialization failed at \(self.modelPath, privacy: .public) — \(error.localizedDescription, privacy: .public)")
            stateLock.withLock { mlxInitialized = false }
            return false
        }
#else
        Self.log.error("MLXLLM not available in this build — add the MLX Swift packages to the target")
        return false
#endif
    }

    /// Metal cache budget for this device, as a fraction of physical RAM, clamped to a sane
    /// range. `physicalMemory` is the device's total RAM, not the app's jetsam budget — hence
    /// the deliberately small fraction.
    private static func deviceScaledCacheLimit() -> Int {
        let memory = tuning.memory
        let physical = Double(ProcessInfo.processInfo.physicalMemory)
        let scaled = Int(physical * memory.metalCacheFraction)
        let floor = memory.metalCacheFloorMB * 1024 * 1024
        let ceiling = memory.metalCacheCeilingMB * 1024 * 1024
        return min(max(scaled, floor), ceiling)
    }

#if canImport(MLXLLM)
    /// Runs one throwaway single-token generation so the first real message doesn't pay for
    /// lazy Metal kernel compilation and first-touch allocation on top of its own prefill.
    /// Failures are ignored on purpose: a model that cannot warm up will report its real error
    /// on the first actual request, and a failed warm-up must never fail initialization.
    private static func warmUp(_ container: ModelContainer) async {
        do {
            let input = UserInput(
                chat: [.user("Hi")],
                additionalContext: ["enable_thinking": false]
            )
            let lmInput = try await container.prepare(input: input)
            let stream = try await container.generate(
                input: lmInput,
                parameters: GenerateParameters(maxTokens: 1, temperature: 0)
            )
            for await _ in stream { break }
        } catch {
            log.debug("warm-up generation skipped — \(error.localizedDescription, privacy: .public)")
        }
    }
#endif

    /// Releases the loaded model and drops MLX's Metal buffer cache. Called on memory
    /// pressure; the next `stream(request:)` call will return placeholder text until
    /// `initializeModel()` is invoked again.
    func unload() {
#if canImport(MLXLLM)
        stateLock.withLock {
            modelContainer = nil
            mlxInitialized = false
            // A kept prefix belongs to the unloaded weights, and memory pressure is exactly when
            // it must not outlive them.
            prefixSnapshot = nil
            previousPromptTokens = nil
            lastGenerationHadMedia = false
        }
        MLX.Memory.clearCache()
#endif
    }

    /// `kvBits`, unless it cannot take effect. In mlx-swift-lm 3.31 a `maxKVSize` gives every
    /// full-attention layer a `RotatingKVCache`, and `maybeQuantizeKVCache` quantizes only
    /// `KVCacheSimple` — so with both set the bits would be silently ignored while the tuning file
    /// claimed a quantized cache. The conflict is resolved once, in favour of the hard memory
    /// bound, and logged. See Docs/BE/mlxApiVerification.md.
    private static let effectiveKVBits: Int? = {
        let generation = tuning.generation
        guard let bits = generation.kvBits else { return nil }
        guard generation.maxKVSize == nil else {
            log.error("kvBits \(bits) ignored: maxKVSize is set, and mlx-swift-lm cannot quantize a rotating KV cache")
            return nil
        }
        return bits
    }()

    // MARK: - LLMServiceProtocol

    func stream(request: LLMRequest) -> AsyncStream<String> {
        let events = generate(request: request)
        return AsyncStream<String>(bufferingPolicy: .bufferingNewest(Self.tokenBufferLimit)) { continuation in
            let task = Task {
                for await event in events {
                    if case let .text(text) = event {
                        continuation.yield(text)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The same generation as `stream`, followed by how it ended: MLX reports whether it stopped
    /// at an end-of-sequence token or at `maxTokens` (`GenerateCompletionInfo.stopReason`).
    func streamEvents(request: LLMRequest) -> AsyncStream<LLMStreamEvent> {
        generate(request: request)
    }

    // MARK: - Private Generation

    private func generate(request: LLMRequest) -> AsyncStream<LLMStreamEvent> {
        return AsyncStream<LLMStreamEvent>(bufferingPolicy: .bufferingNewest(Self.tokenBufferLimit)) { continuation in
            let task = Task.detached(priority: .userInitiated) { [weak self] in
                guard let self = self else {
                    continuation.finish()
                    return
                }

#if canImport(MLXLLM)
                let (mlxReady, readyContainer) = self.stateLock.withLock {
                    (self.mlxInitialized, self.modelContainer)
                }
                if !self.useMock, self.isModelAvailable, mlxReady,
                   let container = readyContainer {
                    do {
                        // Build structured chat messages so container.prepare applies the model's
                        // own chat template (e.g. Qwen's <|im_start|> format) via the tokenizer.
                        // A hand-rolled "System:/User:" string bypasses that template and
                        // measurably degrades output quality.
                        let chat = Self.buildChat(
                            system: request.systemPrompt,
                            history: request.conversationHistory,
                            user: request.userMessage,
                            // Text-only models have no image processor; attaching images to
                            // their chat would make prepare() throw, so drop them up front.
                            images: self.isVisionModel ? request.images : [],
                            allowsImages: self.isVisionModel
                        )
                        // Qwen 3+ hybrid-reasoning templates default to thinking mode, which
                        // would burn the token budget on a <think> preamble and leak it into
                        // the chat. Explicitly disable it; templates without the variable
                        // (Qwen 2.5, Llama, Phi, Gemma) simply ignore it.
                        var input = UserInput(chat: chat, additionalContext: ["enable_thinking": false])
                        // Bound the vision prefill cost — see `visionInputSide`.
                        input.processing.resize = CGSize(
                            width: Self.visionInputSide,
                            height: Self.visionInputSide
                        )
                        let lmInput = try await container.prepare(input: input)
                        // Sampling is per-REQUEST, not per-app. A user-facing answer keeps the
                        // lower-than-default temperature/topP this assistant was tuned around
                        // (higher values let the small multilingual model drift into
                        // English/Chinese/Thai mid-reply); a one-word language classification or a
                        // JSON extraction asks for a greedy, cheap preset instead of silently
                        // inheriting a 1024-token answering budget. See `GenerationOptions`.
                        //
                        // The optional knobs below are applied as property assignments after
                        // construction rather than through the memberwise initializer: that depends
                        // only on the property names existing and being `var` (verified against
                        // mlx-swift-lm 3.31.3 in Docs/BE/mlxApiVerification.md), not on the
                        // initializer's argument order. A knob left nil in InferenceTuning keeps the
                        // runtime's own default. The token ceiling is not one of these knobs: it
                        // comes from the request's GenerationOptions.
                        let options = request.options
                        var params = GenerateParameters(
                            maxTokens: options.maxTokens,
                            temperature: options.temperature,
                            topP: options.topP
                        )
                        let generation = Self.tuning.generation
                        // Prompt tokens processed per prefill step. The runtime default is
                        // already 512; set a smaller value only to bound peak prefill memory on a
                        // constrained device. It shapes how the prompt is computed, not the output.
                        if let prefillStepSize = generation.prefillStepSize {
                            params.prefillStepSize = prefillStepSize
                        }
                        // Quantizing the KV cache cuts its memory 2x at 8 bits, 4x at 4 bits, and
                        // DOES affect output — leave nil until a sweep says otherwise. Only
                        // full-attention layers are quantized; see `effectiveKVBits`.
                        if let kvBits = Self.effectiveKVBits {
                            params.kvBits = kvBits
                            if let kvGroupSize = generation.kvGroupSize {
                                params.kvGroupSize = kvGroupSize
                            }
                            if let quantizedKVStart = generation.quantizedKVStart {
                                params.quantizedKVStart = quantizedKVStart
                            }
                        }
                        // Hard ceiling on cache growth in a long conversation. Old entries are
                        // overwritten once reached, trading continuity for a memory bound.
                        if let maxKVSize = generation.maxKVSize {
                            params.maxKVSize = maxKVSize
                        }
                        let stream = try await self.startGeneration(
                            container: container,
                            input: lmInput,
                            parameters: params,
                            hasSystemPrompt: !request.systemPrompt
                                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                        var completion = LLMCompletion.unknown
                        for await event in stream {
                            if Task.isCancelled { break }
                            switch event {
                            case .chunk(let text):
                                continuation.yield(.text(text))
                            case .info(let info):
                                // `.length`: maxTokens cut the answer off before the model finished,
                                // and the orchestrator tells the patient so.
                                completion = info.stopReason == .length ? .truncated : .finished
                            default:
                                break
                            }
                        }
                        continuation.yield(.completed(completion))
                    } catch {
                        continuation.yield(.text("[MLX error: \(error.localizedDescription)]"))
                        continuation.yield(.completed(.unknown))
                    }
                    continuation.finish()
                    return
                }
#endif // canImport(MLXLLM)

                let reply: String
                if !self.useMock && self.isModelAvailable {
                    reply = "Model found at \(self.modelPath). MLX runtime unavailable for this build; returning placeholder response."
                } else {
                    reply = "Test response: This is local test mode. Model loading disabled. Ready to integrate MLX later."
                }

                for chunk in Self.chunk(reply, size: 48) {
                    if Task.isCancelled { break }
                    continuation.yield(.text(chunk))
                }
                continuation.yield(.completed(.finished))

                continuation.finish()
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func chunk(_ text: String, size: Int) -> [String] {
        guard size > 0 else { return [text] }

        var chunks: [String] = []
        var start = text.startIndex

        while start < text.endIndex {
            let end = text.index(
                start,
                offsetBy: size,
                limitedBy: text.endIndex
            ) ?? text.endIndex

            chunks.append(String(text[start..<end]))
            start = end
        }

        return chunks
    }

#if canImport(MLXLLM)
    // MARK: - Prefix cache

    /// What the prefix cache has done since this model was loaded.
    var prefixCacheStats: PrefixCacheStats {
        stateLock.withLock { prefixStats }
    }

    private var prefixCacheEnabled: Bool {
        prefixCacheOverride ?? Self.tuning.generation.prefixCache
    }

    /// Starts one generation, resuming from the kept prompt prefix when that is known to be safe.
    ///
    /// A cold request takes exactly the path every request took before (`container.generate`).
    /// Resumption needs every condition in `PrefixCachePlanner.isEligible`, and the planner decides
    /// on token ids. The prefix is prefilled, and resumed, inside `container.perform`, which holds the
    /// container for the prefill as `container.generate` does.
    private func startGeneration(
        container: ModelContainer,
        input: sending LMInput,
        parameters: GenerateParameters,
        hasSystemPrompt: Bool
    ) async throws -> AsyncStream<Generation> {
        let hasMedia = input.image != nil || input.video != nil
        let shapeEligible = PrefixCachePlanner.isEligible(
            enabled: prefixCacheEnabled,
            modelType: modelType,
            hasSystemPrompt: hasSystemPrompt,
            hasMedia: hasMedia,
            followsMedia: false,
            hasBoundedCache: parameters.maxKVSize != nil
        )
        // Reading ids copies the prompt to the host; skip it when the answer cannot change.
        let promptIDs = shapeEligible ? PrefixKV.tokenIDs(input.text.tokens) : []

        let (decision, snapshot): (PrefixCachePlanner.Decision, PrefixSnapshot?) = stateLock.withLock {
            let followsMedia = lastGenerationHadMedia
            lastGenerationHadMedia = hasMedia
            guard shapeEligible else { return (.cold, nil) }

            let previous = previousPromptTokens
            previousPromptTokens = promptIDs
            let choice: PrefixCachePlanner.Decision = followsMedia
                ? .cold
                : PrefixCachePlanner.decide(
                    prompt: promptIDs,
                    cachedPrefix: prefixSnapshot?.tokens,
                    previousPrompt: previous
                )
            switch choice {
            case .cold:
                prefixStats.cold += 1
            case .build:
                prefixStats.built += 1
            case .reuse(let length):
                prefixStats.reused += 1
                prefixStats.reusedTokens += length
            }
            return (choice, prefixSnapshot)
        }

        let prefixLength: Int
        let label: String
        switch decision {
        case .cold:
            return try await container.generate(input: input, parameters: parameters)
        case .build(let length):
            prefixLength = length
            label = "build"
        case .reuse(let length):
            prefixLength = length
            label = "reuse"
        }
        Self.log.info("prefix cache \(label, privacy: .public): \(prefixLength) of \(promptIDs.count) prompt tokens")

        return try await container.perform(nonSendable: (input, snapshot)) { [self] context, values in
            let (input, snapshot) = values
            let cache: [KVCache]
            if case .reuse = decision, let snapshot {
                cache = snapshot.cache.map { $0.copy() }
            } else {
                let seeded = try PrefixKV.seed(
                    model: context.model,
                    prefix: PrefixKV.slice(input.text, from: 0, to: prefixLength),
                    parameters: parameters
                )
                let kept = seeded.map { $0.copy() }
                eval(kept)
                self.storePrefixSnapshot(
                    PrefixSnapshot(tokens: Array(promptIDs.prefix(prefixLength)), cache: kept)
                )
                cache = seeded
            }

            let suffix = LMInput(text: PrefixKV.slice(input.text, from: prefixLength, to: nil))
            let iterator = try TokenIterator(
                input: suffix,
                model: PrefixResumingModel(context.model),
                cache: cache,
                parameters: parameters
            )
            let (stream, _) = generateTask(
                promptTokenCount: promptIDs.count - prefixLength,
                modelConfiguration: context.configuration,
                tokenizer: context.tokenizer,
                iterator: iterator
            )
            return stream
        }
    }

    private func storePrefixSnapshot(_ snapshot: PrefixSnapshot) {
        stateLock.withLock { prefixSnapshot = snapshot }
    }

    // MARK: - Chat Builder

    /// Assemble structured chat messages for MLX. `container.prepare` runs these through the
    /// model's chat template, so role labels must NOT be pre-formatted into the text here.
    /// `images` belong to the final user turn; the most recent history user turns carry their
    /// own images (multimodal chat convention) so follow-up questions about a recent photo still
    /// work.
    ///
    /// Older photos are not re-encoded (see `historyImageTurnCap`), but they are not silently
    /// erased either: the turn that carried them is replayed with its text plus a short marker
    /// saying a photo was sent and is no longer attached. Without that marker the model sees a
    /// conversation in which the patient apparently never sent a photo, and a follow-up like
    /// "is what you saw normal?" reads as a non-sequitur — it would answer confidently about
    /// nothing. With it, the model can use what was already said about the photo and ask for a
    /// re-send when it genuinely needs to look again. The marker is only ever added to the copy
    /// fed to the model; the stored message and the UI are untouched.
    ///
    /// Pass `images: []` (and rely on empty `ChatMessage.imageData`) for text-only models.
    /// - Parameter allowsImages: whether the loaded model can see at all. This governs image
    ///   replay, deliberately *instead* of "does the current turn carry a photo" — which is what
    ///   the code used to test. Under that older rule a text-only follow-up ("is that normal?")
    ///   dropped every photo in the conversation, so the one case the replay exists for was
    ///   exactly the case it did not cover. Text-only models pass `false` and never see image
    ///   data or photo markers.
    static func buildChat(
        system: String,
        history: [ChatMessage],
        user: String,
        images: [Data] = [],
        allowsImages: Bool = false
    ) -> [Chat.Message] {
        var messages: [Chat.Message] = []
        let replayableImageTurns = allowsImages ? Self.recentImageTurnIndices(in: history) : []

        let sys = system.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sys.isEmpty {
            messages.append(.system(sys))
        }

        for (index, msg) in history.enumerated() {
            let content = msg.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { continue }

            let role = msg.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            // Only user/assistant turns belong in history; anything else is coerced to user
            // so the chat template never receives an unknown role.
            if role == "assistant" {
                messages.append(.assistant(content))
            } else if replayableImageTurns.contains(index) {
                // Recent enough to be worth re-encoding: the model sees the photo itself.
                messages.append(.user(content, images: Self.mlxImages(from: msg.imageData)))
            } else if allowsImages, !msg.imageData.isEmpty {
                // Too old to re-encode, but the model must still know a photo was sent here.
                messages.append(.user(Self.droppedPhotoMarker(appendedTo: content,
                                                              count: msg.imageData.count)))
            } else {
                messages.append(.user(content))
            }
        }

        messages.append(.user(user, images: Self.mlxImages(from: images)))
        return messages
    }

    /// Text stand-in for a photo that is too old to re-encode. Written in English because the
    /// whole prompt scaffold is English (the model is separately instructed which language to
    /// answer in), and phrased as a statement of fact rather than an instruction so it cannot
    /// be mistaken for something the patient said.
    private static func droppedPhotoMarker(appendedTo content: String, count: Int) -> String {
        let noun = count == 1 ? "a photo" : "\(count) photos"
        return content + "\n[The patient sent \(noun) with this message. The image is no longer "
            + "attached — rely on what has already been said about it, and ask them to send it "
            + "again if you need to look at it.]"
    }

    /// Indices of the last `historyImageTurnCap` history turns that are user turns carrying
    /// images. Everything else replays as text only.
    private static func recentImageTurnIndices(in history: [ChatMessage]) -> Set<Int> {
        let imageTurns = history.indices.filter { index in
            let message = history[index]
            let role = message.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return role != "assistant" && !message.imageData.isEmpty
        }
        return Set(imageTurns.suffix(historyImageTurnCap))
    }

    /// Decode attached image bytes into MLX user-input images; undecodable data is skipped.
    private static func mlxImages(from data: [Data]) -> [UserInput.Image] {
        data.compactMap { bytes in
            CIImage(data: bytes).map { UserInput.Image.ciImage($0) }
        }
    }
#endif
}
