import XCTest
import SwiftData
@testable import MobiCureVN

/// Tests for how `SwiftDataChatHistoryRepository` stores chat photos.
/// A new build passes if:
///   - Images appended to a message come back byte-for-byte from `loadHistory`
///   - Rows written in the legacy inline-JSON format are moved to the external `images`
///     attribute on open, without losing the photos
///   - The conversation list still summarizes messages that carry images
@MainActor
final class ChatHistoryImageStorageTests: XCTestCase {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([ChatRecord.self, ChatConversationRecord.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    private let photos = [Data([0xFF, 0xD8, 0xFF, 0x00, 0x01]), Data(repeating: 0xAB, count: 4096)]

    func testAppendedImagesRoundTrip() async throws {
        let repository = try SwiftDataChatHistoryRepository(container: makeContainer())
        let conversationId = UUID()

        try await repository.append(
            ChatItem(conversationId: conversationId, role: "user", content: "Vết mổ", imageData: photos)
        )

        let history = try await repository.loadHistory(conversationId: conversationId)
        XCTAssertEqual(history.first?.imageData, photos)
    }

    func testLegacyJSONImagesAreMigratedOnOpen() async throws {
        let container = try makeContainer()
        let conversationId = UUID()
        let legacy = ChatRecord(conversationId: conversationId, role: "user", content: "Old photo")
        legacy.imageData = try JSONEncoder().encode(photos)
        container.mainContext.insert(legacy)
        try container.mainContext.save()

        let repository = try SwiftDataChatHistoryRepository(container: container)

        let record = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<ChatRecord>()).first)
        XCTAssertNil(record.imageData)
        XCTAssertNotNil(record.images)
        let history = try await repository.loadHistory(conversationId: conversationId)
        XCTAssertEqual(history.first?.imageData, photos)
    }

    func testConversationSummaryIgnoresImages() async throws {
        let repository = try SwiftDataChatHistoryRepository(container: makeContainer())
        let conversationId = UUID()
        try await repository.append(
            ChatItem(conversationId: conversationId, role: "user", content: "Câu hỏi", date: Date(), imageData: photos)
        )

        let conversations = try await repository.loadConversations()
        XCTAssertEqual(conversations.map(\.id), [conversationId])
        XCTAssertEqual(conversations.first?.title, "Câu hỏi")
        XCTAssertEqual(conversations.first?.messageCount, 1)
    }
}
