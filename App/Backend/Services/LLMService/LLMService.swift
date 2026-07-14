import Foundation

#if canImport(MLXLLM)
import MLX
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers
#endif

nonisolated final class LLMService: @unchecked Sendable, LLMServiceProtocol {
    private let modelPath: String
    private let useMock: Bool
    private let isModelAvailable: Bool
    private var mlxInitialized: Bool = false
    // Guards mlxInitialized/modelContainer: written by initializeModel and read by the
    // detached generation task, potentially on different threads.
    private let stateLock = NSLock()
#if canImport(MLXLLM)
    private var modelContainer: ModelContainer?
#endif

    init(modelPath: String = "qwen-2.5-7b-instruct", useMock: Bool = false) {
        self.modelPath = modelPath
        self.useMock = useMock
        self.isModelAvailable = FileManager.default.fileExists(atPath: modelPath)
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
            let container = try await LLMModelFactory.shared.loadContainer(
                from: modelURL,
                using: #huggingFaceTokenizerLoader()
            )
            stateLock.lock()
            modelContainer = container
            mlxInitialized = true
            stateLock.unlock()
            // Cap Metal's buffer-reuse cache so it doesn't compete unbounded with the
            // OS memory budget on iOS (jetsam will kill the app past its RAM limit).
            MLX.Memory.cacheLimit = 512 * 1024 * 1024
            print("LLMService: MLX initialized at \(modelPath)")
            return true
        } catch {
            print("LLMService: MLX initialization failed — \(error)")
            print("LLMService: model path was: \(modelPath)")
            stateLock.lock()
            mlxInitialized = false
            stateLock.unlock()
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
        modelContainer = nil
        mlxInitialized = false
        MLX.Memory.clearCache()
#endif
    }

    // MARK: - LLMServiceProtocol

    func stream(request: LLMRequest) -> AsyncStream<String> {
#if canImport(MLXLLM)
        let messages = buildChatMessages(
            system: request.systemPrompt,
            history: request.conversationHistory,
            user: request.userMessage
        )
        return generate(messages: messages)
#else
        let prompt = buildPrompt(
            system: request.systemPrompt,
            history: request.conversationHistory,
            user: request.userMessage
        )
        return generate(prompt: prompt)
#endif
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
                self.stateLock.lock()
                let mlxReady = self.mlxInitialized
                let readyContainer = self.modelContainer
                self.stateLock.unlock()
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
                            user: request.userMessage
                        )
                        let input = UserInput(chat: chat)
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
#endif

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
#endif

    private func generate(prompt: String) -> AsyncStream<String> {
        return AsyncStream<String>(bufferingPolicy: .bufferingNewest(512)) { continuation in
            Task.detached(priority: .userInitiated) { [weak self] in
                guard let self = self else {
                    continuation.finish()
                    return
                }

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
    // MARK: - Prompt Builder

#if canImport(MLXLLM)
    /// Builds a role-tagged message list so the model's own chat template puts the
    /// language/behavior directives in a real system turn instead of inside user content.
    /// `UserInput(prompt:)` with a flattened string collapses everything into a single
    /// `.user` message (see `Chat.generate(from:)` in mlx-swift-lm), so the "respond only
    /// in Vietnamese" instruction was just body text the model could deprioritize — a likely
    /// contributor to occasional English/Chinese/Thai drift.
    func buildChatMessages(system: String, history: [ChatMessage], user: String) -> [Chat.Message] {
        var messages: [Chat.Message] = []

        let sys = system.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sys.isEmpty {
            messages.append(.system(sys))
        }

        for msg in history {
            let normalized = msg.role
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            switch normalized {
            case "assistant":
                messages.append(.assistant(msg.content))
            default:
                messages.append(.user(msg.content))
            }
        }

        messages.append(.user(user))
        return messages
    }
#endif

    /// Assemble structured chat messages for MLX. `container.prepare` runs these through the
    /// model's chat template, so role labels must NOT be pre-formatted into the text here.
    private static func buildChat(system: String, history: [ChatMessage], user: String) -> [Chat.Message] {
        var messages: [Chat.Message] = []

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
            messages.append(role == "assistant" ? .assistant(content) : .user(content))
        }

        messages.append(.user(user))
        return messages
    }
#endif
}
