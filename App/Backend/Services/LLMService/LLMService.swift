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

    init(modelPath: String = "qwen-2.5-7b-instruct", useMock: Bool = false) {
        self.modelPath = modelPath
        self.useMock = useMock
        self.isModelAvailable = FileManager.default.fileExists(atPath: modelPath)
    }

    /// MLX loading is temporarily disabled to avoid broken package/module errors.
    /// This keeps the app compiling while we fix the MLX integration separately.
    func initializeModel() async -> Bool {
        print("LLMService: MLX model loading is temporarily disabled.")
        return false
    }

    // MARK: - LLMServiceProtocol

    func stream(request: LLMRequest) -> AsyncStream<String> {
        let prompt = buildPrompt(
            system: request.systemPrompt,
            history: request.conversationHistory,
            user: request.userMessage
        )

        return generate(prompt: prompt)
    }

    // MARK: - Private Generation

    private func generate(prompt: String) -> AsyncStream<String> {
        return AsyncStream<String>(bufferingPolicy: .unbounded) { continuation in
            Task(priority: .userInitiated) { [weak self] in
                guard let self = self else {
                    continuation.finish()
                    return
                }

                let reply: String

                if !self.useMock && self.isModelAvailable {
                    reply = "Model found at \(self.modelPath), but MLX loading is temporarily disabled while fixing package integration."
                } else {
                    reply = "Test response: This is local test mode. Model loading is disabled. Ready to integrate MLX later."
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

    // MARK: - Prompt Builder

    private func buildPrompt(system: String, history: [ChatMessage], user: String) -> String {
        var lines: [String] = []

        let sys = system.trimmingCharacters(in: .whitespacesAndNewlines)

        if !sys.isEmpty {
            lines.append("System: \(sys)")
        }

        for msg in history {
            let normalized = msg.role
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()

            let roleLabel: String

            switch normalized {
            case "user":
                roleLabel = "User"
            case "assistant":
                roleLabel = "Assistant"
            default:
                roleLabel = normalized.capitalized
            }

            lines.append("\(roleLabel): \(msg.content)")
        }

        lines.append("User: \(user)")
        lines.append("Assistant:")

        return lines.joined(separator: "\n")
    }
}
