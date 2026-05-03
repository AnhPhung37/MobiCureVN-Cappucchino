import Foundation

#if canImport(MLXLLM)
import MLXLLM
import MLXLMCommon
import MLXLMTokenizers
import MLXRandom
#endif

final class LLMService: @unchecked Sendable, LLMServiceProtocol {
    private let modelPath: String
    private let useMock: Bool
    private let isModelAvailable: Bool
    private var mlxInitialized: Bool = false
#if canImport(MLXLLM)
    private var modelContainer: ModelContainer?
#endif

    /// Initialize a service with a known local model path. Call `initializeModel()` to attempt MLX init.

    init(modelPath: String = "qwen-2.5-7b-instruct", useMock: Bool = false) {
        self.modelPath = modelPath
        self.useMock = useMock
        self.isModelAvailable = FileManager.default.fileExists(atPath: modelPath)
    }

    /// Attempt to initialize MLX model runtime. Safe to call repeatedly.
    func initializeModel() async {
        if useMock || !isModelAvailable { return }
#if canImport(MLXLLM)
        do {
            let modelURL = URL(fileURLWithPath: modelPath, isDirectory: true)
            let container = try await LLMModelFactory.shared.loadContainer(
                from: modelURL,
                using: TokenizersLoader()
            )
            modelContainer = container
            mlxInitialized = true
            print("LLMService: MLX initialized at \(modelPath)")
        } catch {
            print("LLMService: MLX initialization failed: \(error)")
            mlxInitialized = false
        }
#else
        print("LLMService: MLX not available in this build — cannot initialize runtime")
#endif
    }

    // MARK: - LLMServiceProtocol

    func stream(request: LLMRequest) -> AsyncStream<String> {
        let prompt = buildPrompt(system: request.systemPrompt,
                                history: request.conversationHistory,
                                user: request.userMessage)
        return generate(prompt: prompt)
    }

    // MARK: - Private Generation

    private func generate(prompt: String) -> AsyncStream<String> {
        return AsyncStream<String>(bufferingPolicy: .unbounded) { continuation in
            Task.detached(priority: .userInitiated) { [weak self] in
                guard let self = self else {
                    continuation.finish()
                    return
                }
#if canImport(MLXLLM)
                if !self.useMock, self.isModelAvailable, self.mlxInitialized, let container = self.modelContainer {
                    do {
                        let input = UserInput(prompt: prompt)
                        let prepared = try await container.prepare(input: input)
                        let params = GenerateParameters(maxTokens: 512, temperature: 0.7, topP: 0.9)
                        let stream = try await container.generate(input: prepared, parameters: params)
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
                    reply = "Model found at \(self.modelPath). MLX integration unavailable for this build; returning placeholder response."
                } else {
                    reply = "Test response: This is a local test mode. Model loading disabled. Ready to integrate MLX when needed."
                }
                for chunk in Self.chunk(reply, size: 48) { continuation.yield(chunk) }
                continuation.finish()
            }
        }
    }

    private static func chunk(_ text: String, size: Int) -> [String] {
        guard size > 0 else { return [text] }
        var chunks: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            chunks.append(String(text[start..<end]))
            start = end
        }
        return chunks
    }

    // MARK: - Prompt Builder

    private func buildPrompt(system: String, history: [ChatMessage], user: String) -> String {
        var lines: [String] = []
        let sys = system.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sys.isEmpty {
            lines.append("System: \(sys)")
        }
        for msg in history {
            let normalized = msg.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let roleLabel: String
            switch normalized {
            case "user": roleLabel = "User"
            case "assistant": roleLabel = "Assistant"
            default: roleLabel = normalized.capitalized
            }
            lines.append("\(roleLabel): \(msg.content)")
        }
        lines.append("User: \(user)")
        lines.append("Assistant:")
        return lines.joined(separator: "\n")
    }
}
