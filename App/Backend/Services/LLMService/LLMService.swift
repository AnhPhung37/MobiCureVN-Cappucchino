import Foundation

#if canImport(MLXLLM)
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers
#endif

final class LLMService: @unchecked Sendable, LLMServiceProtocol {
    private let modelPath: String
    private let useMock: Bool
    private let isModelAvailable: Bool
    private var mlxInitialized: Bool = false
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
            modelContainer = container
            mlxInitialized = true
            print("LLMService: MLX initialized at \(modelPath)")
            return true
        } catch {
            print("LLMService: MLX initialization failed — \(error)")
            print("LLMService: model path was: \(modelPath)")
            mlxInitialized = false
            return false
        }
#else
        print("LLMService: MLXLLM not available in this build — add the MLX Swift packages to the target")
        return false
#endif
    }

    // MARK: - LLMServiceProtocol

    func stream(request: LLMRequest) -> AsyncStream<String> {
        return generate(request: request)
    }

    // MARK: - Private Generation

    private func generate(request: LLMRequest) -> AsyncStream<String> {
        return AsyncStream<String>(bufferingPolicy: .unbounded) { continuation in
            Task.detached(priority: .userInitiated) { [weak self] in
                guard let self = self else {
                    continuation.finish()
                    return
                }

#if canImport(MLXLLM)
                if !self.useMock, self.isModelAvailable, self.mlxInitialized,
                   let container = self.modelContainer {
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
                        let params = GenerateParameters(maxTokens: 1024, temperature: 0.7, topP: 0.9)
                        let stream = try await container.generate(input: lmInput, parameters: params)
                        for await event in stream {
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
                    continuation.yield(chunk)
                }

                continuation.finish()
            }
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
