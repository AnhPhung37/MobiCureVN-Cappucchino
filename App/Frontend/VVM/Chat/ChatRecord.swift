import Foundation
import SwiftData

@Model
final class ChatRecord {
    @Attribute(.unique) var id: UUID
    var conversationId: UUID?
    var role: String
    var content: String
    var date: Date

    init(id: UUID = UUID(), conversationId: UUID? = nil, role: String, content: String, date: Date = Date()) {
        self.id = id
        self.conversationId = conversationId
        self.role = role
        self.content = content
        self.date = date
    }
}
