import Foundation

protocol ChatHistoryRepository {
    func loadConversations() async throws -> [ChatConversationSummary]
    func loadHistory() async throws -> [ChatItem]
    func loadHistory(conversationId: UUID) async throws -> [ChatItem]
    func append(_ item: ChatItem) async throws
    func deleteConversation(id: UUID) async throws
    func clear() async throws
}
