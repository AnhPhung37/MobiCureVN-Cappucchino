import Foundation

public actor ChatOrchestrator {
    private var memory: ConversationMemory
    private let llm: LLMService
    private let toolExecutor: ToolExecutor?
    private let maxToolLoops = 2

    public init(
        llm: LLMService = LLMService(),
        memory: ConversationMemory = ConversationMemory(),
        toolExecutor: ToolExecutor? = ToolExecutor()
    ) {
        self.llm = llm
        self.memory = memory
        self.toolExecutor = toolExecutor
    }

    public func handleMessage(_ input: String) async -> ChatResponse {
        memory.append(ChatMessage(role: "user", content: input))

        var reply = ""
        var loops = 0

        while loops < maxToolLoops {
            let prompt = buildPrompt()
            let stream = llm.generate(prompt: prompt)
            let output = await collect(stream)

            if let toolCall = parseToolCall(output), let toolExecutor {
                let toolResult = toolExecutor.execute(name: toolCall.name, args: toolCall.args)
                memory.append(ChatMessage(role: "assistant", content: "TOOL_RESULT: \(toolResult)"))
                loops += 1
                continue
            }

            reply = output
            break
        }

        if reply.isEmpty {
            reply = "I can share general information, but please consult a clinician for medical advice."
        }

        memory.append(ChatMessage(role: "assistant", content: reply))
        return ChatResponse(reply: reply)
    }

    private func buildPrompt() -> String {
        var prompt = "SYSTEM: You are a medical support assistant. Do not diagnose or prescribe. Suggest consulting a doctor.\n"
        if toolExecutor != nil {
            prompt += "If you need a tool, respond ONLY with JSON: {\"tool\":\"calculator\",\"args\":{\"expression\":\"2+2\"}}\n"
        }
        prompt += "CONVERSATION:\n"
        for message in memory.recent() {
            prompt += "\(message.role.uppercased()): \(message.content)\n"
        }
        return prompt
    }

    private func collect(_ stream: AsyncStream<String>) async -> String {
        var output = ""
        for await chunk in stream {
            output += chunk
        }
        return output
    }

    private func parseToolCall(_ text: String) -> (name: String, args: [String: Any])? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}") else {
            return nil
        }
        let json = String(trimmed[start...end])
        guard let data = json.data(using: .utf8) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let name = object["tool"] as? String else { return nil }
        let args = object["args"] as? [String: Any] ?? [:]
        return (name, args)
    }
}
