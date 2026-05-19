import Foundation

public struct ChatMessage: Sendable {
    public let role: String
    public let content: String
    public let sources: [MedicalSource]

    public init(role: String, content: String, sources: [MedicalSource] = []) {
        self.role = role
        self.content = content
        self.sources = sources
    }
}

public struct ChatResponse: Sendable {
    public let reply: String

    public init(reply: String) {
        self.reply = reply
    }
}
