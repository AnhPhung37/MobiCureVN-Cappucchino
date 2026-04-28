import Foundation

public struct ConversationMemory: Sendable {
    public private(set) var messages: [ChatMessage]
    private let maxMessages: Int

    public init(maxMessages: Int = 15) {
        self.maxMessages = max(1, maxMessages)
        self.messages = []
    }

    public mutating func append(_ message: ChatMessage) {
        messages.append(message)
        if messages.count > maxMessages {
            messages.removeFirst(messages.count - maxMessages)
        }
    }

    public func recent() -> [ChatMessage] {
        messages
    }
}
