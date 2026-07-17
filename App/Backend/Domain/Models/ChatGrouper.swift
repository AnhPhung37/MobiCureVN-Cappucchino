import Foundation

struct ChatSection: Identifiable, Sendable {
    let id: String
    let title: String
    let items: [ChatItem]
}

enum ChatGrouper {
    static func group(_ items: [ChatItem], now: Date = Date(), calendar: Calendar = .current) -> [ChatSection] {
        let startOfToday = calendar.startOfDay(for: now)
        guard let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday),
              let startOf7Days = calendar.date(byAdding: .day, value: -7, to: startOfToday),
              let startOf30Days = calendar.date(byAdding: .day, value: -30, to: startOfToday) else {
            return []
        }

        var today: [ChatItem] = []
        var yesterday: [ChatItem] = []
        var last7Days: [ChatItem] = []
        var last1Month: [ChatItem] = []
        var older: [ChatItem] = []

        for item in items {
            let d = item.date
            // No upper bound on "today" so future-dated items (clock skew) still appear,
            // matching ChatConversationGrouper rather than silently vanishing.
            if d >= startOfToday {
                today.append(item)
            } else if d >= startOfYesterday {
                yesterday.append(item)
            } else if d >= startOf7Days {
                last7Days.append(item)
            } else if d >= startOf30Days {
                last1Month.append(item)
            } else {
                older.append(item)
            }
        }

        var sections: [ChatSection] = []
        if !today.isEmpty {
            sections.append(ChatSection(id: "today", title: "Today", items: today))
        }
        if !yesterday.isEmpty {
            sections.append(ChatSection(id: "yesterday", title: "Yesterday", items: yesterday))
        }
        if !last7Days.isEmpty {
            sections.append(ChatSection(id: "last7days", title: "Last 7 Days", items: last7Days))
        }
        if !last1Month.isEmpty {
            sections.append(ChatSection(id: "last1month", title: "Last 1 Month", items: last1Month))
        }
        if !older.isEmpty {
            sections.append(ChatSection(id: "older", title: "Older", items: older))
        }
        return sections
    }
}
