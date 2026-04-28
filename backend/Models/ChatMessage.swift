import Foundation

public struct ChatMessage: Sendable {
    public let role: String
    public let content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

public struct ChatResponse: Sendable {
    public let reply: String

    public init(reply: String) {
        self.reply = reply
    }
}
