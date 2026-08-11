import Foundation

protocol ChatHistoryRepository {
    func loadConversations() async throws -> [ChatConversationSummary]
    func loadHistory(conversationId: UUID) async throws -> [ChatItem]
    func append(_ item: ChatItem) async throws
    func deleteConversation(id: UUID) async throws
    /// Wipes every stored conversation — the "delete all history" action.
    func deleteAllConversations() async throws
    /// Overrides the auto-derived title of a conversation. Passing a blank title (or `nil`)
    /// clears the override so the conversation goes back to being titled by its first user
    /// message.
    func renameConversation(id: UUID, title: String?) async throws
}
