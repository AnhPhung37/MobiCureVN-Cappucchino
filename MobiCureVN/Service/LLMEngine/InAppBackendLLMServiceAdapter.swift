import Foundation

/// Thin adapter that bridges the app's in-app backend `LLMService` to the UI-facing `LLMServiceProtocol`.
/// It builds a simple role-tagged prompt from `LLMRequest` and streams tokens via the backend.
final class InAppBackendLLMServiceAdapter: LLMServiceProtocol {
    private let backend: LLMService

    init(backend: LLMService = LLMService()) {
        self.backend = backend
    }

    func stream(request: LLMRequest) -> AsyncStream<String> {
        let prompt = Self.buildPrompt(system: request.systemPrompt,
                                      history: request.conversationHistory,
                                      user: request.userMessage)
        // Delegate to backend's generator; it already returns AsyncStream<String>
        let backendStream = backend.generate(prompt: prompt)

        // Wrap to allow cooperative cancellation if needed
        return AsyncStream { continuation in
            Task {
                for await chunk in backendStream {
                    if Task.isCancelled { break }
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
        }
    }

    // MARK: - Prompt Builder

    private static func buildPrompt(system: String, history: [ChatMessage], user: String) -> String {
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
