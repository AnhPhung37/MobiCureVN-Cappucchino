import Foundation

struct ChatItem: Identifiable, Sendable {
    let id: UUID
    let conversationId: UUID
    let role: String
    let content: String
    let date: Date

    init(
        id: UUID = UUID(),
        conversationId: UUID = UUID(),
        role: String,
        content: String,
        date: Date = Date()
    ) {
        self.id = id
        self.conversationId = conversationId
        self.role = role
        self.content = content
        self.date = date
    }
}
