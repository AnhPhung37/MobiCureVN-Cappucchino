import Foundation

actor InMemoryChatHistoryRepository: ChatHistoryRepository {
    private var items: [ChatItem] = []
    /// Patient renames keyed by conversation id — mirrors `ChatConversationRecord` in the
    /// SwiftData store. Only renamed conversations have an entry.
    private var customTitles: [UUID: String] = [:]

    func loadConversations() async throws -> [ChatConversationSummary] {
        let grouped = Dictionary(grouping: items) { $0.conversationId }
        return ChatConversationSummary.summarizing(
            grouped,
            customTitles: customTitles,
            date: \.date,
            role: \.role,
            content: \.content
        )
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
        customTitles[id] = nil
    }

    func deleteAllConversations() async throws {
        items.removeAll()
        customTitles.removeAll()
    }

    func renameConversation(id: UUID, title: String?) async throws {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        customTitles[id] = trimmed.isEmpty ? nil : trimmed
    }
}
