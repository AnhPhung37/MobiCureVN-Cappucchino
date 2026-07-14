import Foundation
import SwiftData

@Model
final class ChatRecord {
    @Attribute(.unique) var id: UUID
    var conversationId: UUID?
    var role: String
    var content: String
    var date: Date
    /// JSON-encoded `[MedicalSource]` for assistant messages. Optional so existing stores
    /// migrate without data loss; nil for user messages or answers without citations.
    var sourcesData: Data?

    init(id: UUID = UUID(), conversationId: UUID? = nil, role: String, content: String, date: Date = Date(), sourcesData: Data? = nil) {
        self.id = id
        self.conversationId = conversationId
        self.role = role
        self.content = content
        self.date = date
        self.sourcesData = sourcesData
    }
}
