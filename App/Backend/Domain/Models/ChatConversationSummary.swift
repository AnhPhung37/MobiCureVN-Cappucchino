import Foundation

nonisolated struct ChatConversationSummary: Identifiable, Sendable {
    let id: UUID
    let title: String
    let preview: String
    let lastMessageDate: Date
    let messageCount: Int
    /// True when `title` came from a patient rename rather than the first user message. The
    /// rename sheet uses it to decide whether "restore the automatic title" is on offer.
    let hasCustomTitle: Bool

    init(id: UUID, title: String, preview: String, lastMessageDate: Date, messageCount: Int, hasCustomTitle: Bool = false) {
        self.id = id
        self.title = title
        self.preview = preview
        self.lastMessageDate = lastMessageDate
        self.messageCount = messageCount
        self.hasCustomTitle = hasCustomTitle
    }

    // Shared by SwiftDataChatHistoryRepository and InMemoryChatHistoryRepository so both
    // build conversation summaries — sorted newest-first — the same way regardless of the
    // underlying storage's message type. `customTitles` holds patient renames keyed by
    // conversation id; a conversation without an entry is titled by its first user message.
    static func summarizing<Message>(
        _ grouped: [UUID: [Message]],
        customTitles: [UUID: String] = [:],
        date: (Message) -> Date,
        role: (Message) -> String,
        content: (Message) -> String
    ) -> [ChatConversationSummary] {
        grouped.map { conversationId, messages in
            let sorted = messages.sorted { date($0) < date($1) }
            let preview = sorted.last.map(content) ?? ""
            let derivedTitle = sorted.first(where: { role($0).lowercased() == "user" }).map(content) ?? preview
            let customTitle = customTitles[conversationId]
            let title = customTitle ?? (derivedTitle.isEmpty ? "Chat" : derivedTitle)
            return ChatConversationSummary(
                id: conversationId,
                title: title,
                preview: preview,
                lastMessageDate: sorted.last.map(date) ?? Date(),
                messageCount: sorted.count,
                hasCustomTitle: customTitle != nil
            )
        }
        .sorted { $0.lastMessageDate > $1.lastMessageDate }
    }
}

struct ChatConversationSection: Identifiable, Sendable {
    let id: String
    let title: String
    let items: [ChatConversationSummary]
}

enum ChatConversationGrouper {
    static func group(_ items: [ChatConversationSummary], now: Date = Date(), calendar: Calendar = .current) -> [ChatConversationSection] {
        let startOfToday = calendar.startOfDay(for: now)
        guard let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday),
              let startOf7Days = calendar.date(byAdding: .day, value: -7, to: startOfToday),
              let startOf30Days = calendar.date(byAdding: .day, value: -30, to: startOfToday) else {
            return []
        }

        var today: [ChatConversationSummary] = []
        var yesterday: [ChatConversationSummary] = []
        var last7Days: [ChatConversationSummary] = []
        var last1Month: [ChatConversationSummary] = []
        var older: [ChatConversationSummary] = []

        for item in items {
            let date = item.lastMessageDate
            if date >= startOfToday {
                today.append(item)
            } else if date >= startOfYesterday {
                yesterday.append(item)
            } else if date >= startOf7Days {
                last7Days.append(item)
            } else if date >= startOf30Days {
                last1Month.append(item)
            } else {
                older.append(item)
            }
        }

        var sections: [ChatConversationSection] = []
        if !today.isEmpty {
            sections.append(ChatConversationSection(id: "today", title: "Today", items: today))
        }
        if !yesterday.isEmpty {
            sections.append(ChatConversationSection(id: "yesterday", title: "Yesterday", items: yesterday))
        }
        if !last7Days.isEmpty {
            sections.append(ChatConversationSection(id: "last7days", title: "Last 7 Days", items: last7Days))
        }
        if !last1Month.isEmpty {
            sections.append(ChatConversationSection(id: "last1month", title: "Last 1 Month", items: last1Month))
        }
        if !older.isEmpty {
            sections.append(ChatConversationSection(id: "older", title: "Older", items: older))
        }

        return sections
    }
}
