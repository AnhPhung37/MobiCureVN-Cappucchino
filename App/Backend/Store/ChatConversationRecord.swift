import Foundation
import SwiftData

/// Conversation-level metadata that isn't derivable from the messages themselves.
///
/// Titles are normally derived from a conversation's first user message (see
/// `ChatConversationSummary.summarizing`), so a row exists here only once the patient renames
/// a conversation. Keeping it in its own table — rather than denormalising a title onto every
/// `ChatRecord` — means a rename is a single write and later per-conversation metadata
/// (pinning, archiving) has an obvious home.
@Model
final class ChatConversationRecord {
    @Attribute(.unique) var conversationId: UUID
    /// Patient-chosen title. Always non-empty: clearing the title deletes the record so the
    /// conversation falls back to its auto-derived title.
    var title: String
    var updatedAt: Date

    init(conversationId: UUID, title: String, updatedAt: Date = Date()) {
        self.conversationId = conversationId
        self.title = title
        self.updatedAt = updatedAt
    }
}
