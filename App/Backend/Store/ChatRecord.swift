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
    /// Attached images as a binary-plist `[Data]` (raw bytes, no base64). `.externalStorage`
    /// keeps the blob out of the SQLite row, so fetching messages — e.g. for the conversation
    /// list — doesn't drag every photo along. Optional, so adding it is a lightweight migration.
    @Attribute(.externalStorage) var images: Data?
    /// Legacy inline JSON-encoded `[Data]` (base64 per image). No longer written; existing rows
    /// are moved into `images` by `SwiftDataChatHistoryRepository` on open.
    var imageData: Data?

    init(id: UUID = UUID(), conversationId: UUID? = nil, role: String, content: String, date: Date = Date(), sourcesData: Data? = nil, images: Data? = nil) {
        self.id = id
        self.conversationId = conversationId
        self.role = role
        self.content = content
        self.date = date
        self.sourcesData = sourcesData
        self.images = images
    }
}
