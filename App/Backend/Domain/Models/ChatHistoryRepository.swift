import Foundation

protocol ChatHistoryRepository {
    func loadConversations() async throws -> [ChatConversationSummary]
    func loadHistory() async throws -> [ChatItem]
    func loadHistory(conversationId: UUID) async throws -> [ChatItem]
    func append(_ item: ChatItem) async throws
    func deleteConversation(id: UUID) async throws
    func clear() async throws
}

actor InMemoryChatHistoryRepository: ChatHistoryRepository {
    private var items: [ChatItem] = []

    func loadConversations() async throws -> [ChatConversationSummary] {
        let grouped = Dictionary(grouping: items) { $0.conversationId }
        return grouped.map { conversationId, messages in
            let sorted = messages.sorted { $0.date < $1.date }
            let preview = sorted.last?.content ?? ""
            let title = sorted.first(where: { $0.role.lowercased() == "user" })?.content ?? preview
            return ChatConversationSummary(
                id: conversationId,
                title: title.isEmpty ? "Chat" : title,
                preview: preview,
                lastMessageDate: sorted.last?.date ?? Date(),
                messageCount: sorted.count
            )
        }
        .sorted { $0.lastMessageDate > $1.lastMessageDate }
    }

    func loadHistory() async throws -> [ChatItem] {
        return items.sorted { $0.date < $1.date }
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

    func clear() async throws {
        items.removeAll()
    }
}
