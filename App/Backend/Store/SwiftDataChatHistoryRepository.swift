import Foundation
import SwiftData

@MainActor
final class SwiftDataChatHistoryRepository: ChatHistoryRepository {

    private static let legacyConversationId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    private let container: ModelContainer

    init(container: ModelContainer? = nil) throws {
        if let container {
            self.container = container
        } else {
            self.container = try ModelContainer(for: ChatRecord.self)
        }
    }

    func loadConversations() async throws -> [ChatConversationSummary] {
        let descriptor = FetchDescriptor<ChatRecord>(sortBy: [SortDescriptor(\.date, order: .forward)])
        let records = try container.mainContext.fetch(descriptor)
        let grouped = Dictionary(grouping: records) { record -> UUID in
            record.conversationId ?? Self.legacyConversationId
        }

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
        let descriptor = FetchDescriptor<ChatRecord>(
            sortBy: [SortDescriptor(\.date, order: .forward)]
        )
        let records = try container.mainContext.fetch(descriptor)
        return records.map { record in
            ChatItem(
                id: record.id,
                conversationId: record.conversationId ?? Self.legacyConversationId,
                role: record.role,
                content: record.content,
                date: record.date
            )
        }
    }

    func loadHistory(conversationId: UUID) async throws -> [ChatItem] {
        let descriptor = FetchDescriptor<ChatRecord>(
            sortBy: [SortDescriptor(\.date, order: .forward)]
        )
        let records = try container.mainContext.fetch(descriptor)
        return records
            .filter { ($0.conversationId ?? Self.legacyConversationId) == conversationId }
            .map { record in
                ChatItem(
                    id: record.id,
                    conversationId: record.conversationId ?? Self.legacyConversationId,
                    role: record.role,
                    content: record.content,
                    date: record.date
                )
            }
    }

    func append(_ item: ChatItem) async throws {
        let record = ChatRecord(
            id: item.id,
            conversationId: item.conversationId,
            role: item.role,
            content: item.content,
            date: item.date
        )
        container.mainContext.insert(record)
        try container.mainContext.save()
    }

    func deleteConversation(id: UUID) async throws {
        let descriptor = FetchDescriptor<ChatRecord>()
        let records = try container.mainContext.fetch(descriptor)
        for record in records where (record.conversationId ?? Self.legacyConversationId) == id {
            container.mainContext.delete(record)
        }
        try container.mainContext.save()
    }

    func clear() async throws {
        let descriptor = FetchDescriptor<ChatRecord>()
        let records = try container.mainContext.fetch(descriptor)
        for record in records {
            container.mainContext.delete(record)
        }
        try container.mainContext.save()
    }
}