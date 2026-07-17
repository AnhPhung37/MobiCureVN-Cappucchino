import Foundation

actor InMemoryChatHistoryRepository: ChatHistoryRepository {
    private var items: [ChatItem] = []

    func loadConversations() async throws -> [ChatConversationSummary] {
        let grouped = Dictionary(grouping: items) { $0.conversationId }
        return ChatConversationSummary.summarizing(grouped, date: \.date, role: \.role, content: \.content)
    }

    func loadHistory(conversationId: UUID) async throws -> [ChatItem] {
        items
            .filter { $0.conversationId == conversationId }
            .sorted { $0.date < $1.date }
    }

    func append(_ item: ChatItem) async throws {
        items.append(item)
    }

    func deleteConversation(id: UUID) async throws {
        items.removeAll { $0.conversationId == id }
    }
}
