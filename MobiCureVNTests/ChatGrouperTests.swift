import XCTest
@testable import MobiCureVN

/// Tests for ChatGrouper and ChatConversationGrouper — verifies date-based section grouping.
/// A new build passes if:
///   - Messages are placed in the correct time bucket (Today/Yesterday/Last 7 Days/Last 1 Month/Older)
///   - Empty input produces no sections
///   - Section titles are correct
///   - Multiple items in the same bucket stay together
@MainActor
final class ChatGrouperTests: XCTestCase {

    private var calendar: Calendar!
    private var now: Date!

    override func setUp() {
        super.setUp()
        calendar = Calendar.current
        now = Date()
    }

    private func makeItem(daysAgo: Int, role: String = "user") -> ChatItem {
        let date = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
        return ChatItem(
            id: UUID(),
            conversationId: UUID(),
            role: role,
            content: "Test message",
            date: date
        )
    }

    // MARK: - Edge Cases

    func testEmptyInputProducesNoSections() {
        let sections = ChatGrouper.group([], now: now, calendar: calendar)
        XCTAssertTrue(sections.isEmpty)
    }

    // MARK: - Bucket Placement

    func testTodayItemGoesToTodaySection() {
        let item = makeItem(daysAgo: 0)
        let sections = ChatGrouper.group([item], now: now, calendar: calendar)
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].id, "today")
        XCTAssertEqual(sections[0].items.count, 1)
    }

    func testYesterdayItemGoesToYesterdaySection() {
        let item = makeItem(daysAgo: 1)
        let sections = ChatGrouper.group([item], now: now, calendar: calendar)
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].id, "yesterday")
    }

    func testFourDaysAgoGoesToLast7DaysSection() {
        let item = makeItem(daysAgo: 4)
        let sections = ChatGrouper.group([item], now: now, calendar: calendar)
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].id, "last7days")
    }

    func testFifteenDaysAgoGoesToLast1MonthSection() {
        let item = makeItem(daysAgo: 15)
        let sections = ChatGrouper.group([item], now: now, calendar: calendar)
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].id, "last1month")
    }

    func testFortyFiveDaysAgoGoesToOlderSection() {
        let item = makeItem(daysAgo: 45)
        let sections = ChatGrouper.group([item], now: now, calendar: calendar)
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].id, "older")
    }

    // MARK: - Multiple Sections

    func testMixedItemsCreateCorrectSections() {
        let items = [
            makeItem(daysAgo: 0),
            makeItem(daysAgo: 1),
            makeItem(daysAgo: 4),
            makeItem(daysAgo: 45)
        ]
        let sections = ChatGrouper.group(items, now: now, calendar: calendar)
        XCTAssertEqual(sections.count, 4)
        XCTAssertEqual(sections[0].id, "today")
        XCTAssertEqual(sections[1].id, "yesterday")
        XCTAssertEqual(sections[2].id, "last7days")
        XCTAssertEqual(sections[3].id, "older")
    }

    func testAllFiveSectionsCreated() {
        let items = [
            makeItem(daysAgo: 0),
            makeItem(daysAgo: 1),
            makeItem(daysAgo: 4),
            makeItem(daysAgo: 15),
            makeItem(daysAgo: 45)
        ]
        let sections = ChatGrouper.group(items, now: now, calendar: calendar)
        XCTAssertEqual(sections.count, 5)
    }

    // MARK: - Section Titles

    func testSectionTitlesAreCorrect() {
        let items = [
            makeItem(daysAgo: 0),
            makeItem(daysAgo: 1),
            makeItem(daysAgo: 4),
            makeItem(daysAgo: 15),
            makeItem(daysAgo: 45)
        ]
        let sections = ChatGrouper.group(items, now: now, calendar: calendar)
        XCTAssertEqual(sections[0].title, "Today")
        XCTAssertEqual(sections[1].title, "Yesterday")
        XCTAssertEqual(sections[2].title, "Last 7 Days")
        XCTAssertEqual(sections[3].title, "Last 1 Month")
        XCTAssertEqual(sections[4].title, "Older")
    }

    // MARK: - Multiple Items Per Section

    func testMultipleTodayItemsGroupedTogether() {
        let items = [makeItem(daysAgo: 0), makeItem(daysAgo: 0), makeItem(daysAgo: 0)]
        let sections = ChatGrouper.group(items, now: now, calendar: calendar)
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].id, "today")
        XCTAssertEqual(sections[0].items.count, 3)
    }

    func testMultipleItemsInDifferentSectionsCountCorrectly() {
        let items = [
            makeItem(daysAgo: 0),
            makeItem(daysAgo: 0),
            makeItem(daysAgo: 1),
            makeItem(daysAgo: 4),
            makeItem(daysAgo: 4),
        ]
        let sections = ChatGrouper.group(items, now: now, calendar: calendar)
        XCTAssertEqual(sections.count, 3)
        XCTAssertEqual(sections[0].items.count, 2) // today
        XCTAssertEqual(sections[1].items.count, 1) // yesterday
        XCTAssertEqual(sections[2].items.count, 2) // last 7 days
    }

    // MARK: - Section IDs Are Stable

    func testSectionIDsAreExpectedValues() {
        let items = [
            makeItem(daysAgo: 0),
            makeItem(daysAgo: 1),
            makeItem(daysAgo: 4),
            makeItem(daysAgo: 15),
            makeItem(daysAgo: 45)
        ]
        let sections = ChatGrouper.group(items, now: now, calendar: calendar)
        let ids = sections.map(\.id)
        XCTAssertEqual(ids, ["today", "yesterday", "last7days", "last1month", "older"])
    }
}

// MARK: - ChatConversationGrouper Tests

@MainActor
final class ChatConversationGrouperTests: XCTestCase {

    private var calendar: Calendar!
    private var now: Date!

    override func setUp() {
        super.setUp()
        calendar = Calendar.current
        now = Date()
    }

    private func makeSummary(daysAgo: Int) -> ChatConversationSummary {
        let date = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
        return ChatConversationSummary(
            id: UUID(),
            title: "Conversation",
            preview: "Preview text",
            lastMessageDate: date,
            messageCount: 3
        )
    }

    func testEmptyInputProducesNoSections() {
        let sections = ChatConversationGrouper.group([], now: now, calendar: calendar)
        XCTAssertTrue(sections.isEmpty)
    }

    func testTodayConversationPlacedCorrectly() {
        let summary = makeSummary(daysAgo: 0)
        let sections = ChatConversationGrouper.group([summary], now: now, calendar: calendar)
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].id, "today")
    }

    func testOlderConversationPlacedCorrectly() {
        let summary = makeSummary(daysAgo: 60)
        let sections = ChatConversationGrouper.group([summary], now: now, calendar: calendar)
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].id, "older")
    }
}
