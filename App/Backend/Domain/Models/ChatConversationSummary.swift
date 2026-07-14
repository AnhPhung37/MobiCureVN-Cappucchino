import Foundation

nonisolated struct ChatConversationSummary: Identifiable, Sendable {
    let id: UUID
    let title: String
    let preview: String
    let lastMessageDate: Date
    let messageCount: Int

    init(id: UUID, title: String, preview: String, lastMessageDate: Date, messageCount: Int) {
        self.id = id
        self.title = title
        self.preview = preview
        self.lastMessageDate = lastMessageDate
        self.messageCount = messageCount
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