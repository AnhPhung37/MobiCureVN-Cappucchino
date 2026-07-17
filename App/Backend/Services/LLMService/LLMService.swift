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

    init(modelPath: String = "qwen-2.5-7b-instruct", useMock: Bool = false) {
        self.modelPath = modelPath
        self.useMock = useMock
        self.isModelAvailable = FileManager.default.fileExists(atPath: modelPath)
        self.isVisionModel = Self.detectVisionModel(at: modelPath)
    }

    /// model_type values registered by MLXVLM's VLMModelFactory. Text-only exports use
    /// distinct types (e.g. Gemma 3's text-only repos are "gemma3_text"), so this set is
    /// safe to match exactly.
    private static let visionModelTypes: Set<String> = [
        "qwen2_vl", "qwen2_5_vl", "qwen3_vl", "gemma3", "paligemma", "idefics3", "smolvlm", "llava"
    ]

    private static func detectVisionModel(at path: String) -> Bool {
        let configURL = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let modelType = json["model_type"] as? String else {
            return false
        }
        return visionModelTypes.contains(modelType.lowercased())
    }

    func initializeModel() async -> Bool {
        guard !useMock else {
            print("LLMService: useMock=true, skipping MLX init")
            return false
        }
        guard isModelAvailable else {
            print("LLMService: model path not found: \(modelPath)")
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
            // OS memory budget on iOS (jetsam will kill the app past its RAM limit).
            MLX.Memory.cacheLimit = 512 * 1024 * 1024
            print("LLMService: MLX initialized at \(modelPath)")
            return true
        } catch {
            print("LLMService: MLX initialization failed — \(error)")
            print("LLMService: model path was: \(modelPath)")
            stateLock.withLock { mlxInitialized = false }
            return false
        }
#else
        print("LLMService: MLXLLM not available in this build — add the MLX Swift packages to the target")
        return false
#endif
    }

    /// Releases the loaded model and drops MLX's Metal buffer cache. Called on memory
    /// pressure; the next `stream(request:)` call will return placeholder text until
    /// `initializeModel()` is invoked again.
    func unload() {
#if canImport(MLXLLM)
        stateLock.withLock {
            modelContainer = nil
            mlxInitialized = false
        }
        MLX.Memory.clearCache()
#endif
    }

    // MARK: - LLMServiceProtocol

    func stream(request: LLMRequest) -> AsyncStream<String> {
        return generate(request: request)
    }

    // MARK: - Private Generation

    private func generate(request: LLMRequest) -> AsyncStream<String> {
        return AsyncStream<String>(bufferingPolicy: .unbounded) { continuation in
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
                            images: self.isVisionModel ? request.images : []
                        )
                        var input = UserInput(chat: chat)
                        // Bound the vision prefill cost: a full-resolution photo expands into
                        // thousands of image tokens on a 3B VLM. 512px is plenty for wound /
                        // medication-label photos and keeps prefill in the seconds range.
                        input.processing.resize = CGSize(width: 512, height: 512)
                        let lmInput = try await container.prepare(input: input)
                        // Lower temperature/topP than default: this is a medical Q&A assistant where
                        // deterministic, on-language output matters more than lexical variety. Higher
                        // values let the small multilingual model drift into English/Chinese/Thai mid-reply.
                        let params = GenerateParameters(maxTokens: 1024, temperature: 0.3, topP: 0.85)
                        let stream = try await container.generate(input: lmInput, parameters: params)
                        for await event in stream {
                            if Task.isCancelled { break }
                            if case let .chunk(text) = event {
                                continuation.yield(text)
                            }
                        }
                    } catch {
                        continuation.yield("[MLX error: \(error.localizedDescription)]")
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
                    continuation.yield(chunk)
                }

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
    // MARK: - Chat Builder

    /// Assemble structured chat messages for MLX. `container.prepare` runs these through the
    /// model's chat template, so role labels must NOT be pre-formatted into the text here.
    /// `images` belong to the final user turn; history user turns carry their own images
    /// (multimodal chat convention) so follow-up questions about an earlier photo still work.
    /// Pass `images: []` (and rely on empty `ChatMessage.imageData`) for text-only models.
    static func buildChat(
        system: String,
        history: [ChatMessage],
        user: String,
        images: [Data] = []
    ) -> [Chat.Message] {
        var messages: [Chat.Message] = []
        let attachImages = !images.isEmpty

        let sys = system.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sys.isEmpty {
            messages.append(.system(sys))
        }

        for msg in history {
            let content = msg.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { continue }

            let role = msg.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            // Only user/assistant turns belong in history; anything else is coerced to user
            // so the chat template never receives an unknown role.
            if role == "assistant" {
                messages.append(.assistant(content))
            } else {
                // Only re-attach history images when this turn itself carries images —
                // i.e. we're talking to a vision model. Keeps text-only requests clean.
                let historyImages = attachImages ? Self.mlxImages(from: msg.imageData) : []
                messages.append(.user(content, images: historyImages))
            }
        }

        messages.append(.user(user, images: Self.mlxImages(from: images)))
        return messages
    }

    /// Decode attached image bytes into MLX user-input images; undecodable data is skipped.
    private static func mlxImages(from data: [Data]) -> [UserInput.Image] {
        data.compactMap { bytes in
            CIImage(data: bytes).map { UserInput.Image.ciImage($0) }
        }
    }
#endif
}
