import XCTest
import SwiftData
@testable import MobiCureVN

/// Tests for the chat-session management actions — delete one, delete all, rename — across
/// both `ChatHistoryRepository` implementations, so the SwiftData store and the in-memory
/// fallback behave identically.
/// A new build passes if:
///   - Deleting a conversation removes only that conversation's messages
///   - Deleting a conversation also drops its rename, so a reused id isn't re-titled
///   - Delete-all leaves no conversations behind
///   - A renamed conversation reports the custom title (and is flagged as custom)
///   - A blank rename restores the title derived from the first user message
@MainActor
final class ChatSessionManagementTests: XCTestCase {

    private func makeSwiftDataRepository() throws -> SwiftDataChatHistoryRepository {
        let schema = Schema([ChatRecord.self, ChatConversationRecord.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        return try SwiftDataChatHistoryRepository(container: container)
    }

    /// Seeds a two-message conversation (user then assistant) and returns its id.
    @discardableResult
    private func seedConversation(
        in repository: ChatHistoryRepository,
        userText: String,
        assistantText: String = "Assistant reply",
        startingAt date: Date = Date()
    ) async throws -> UUID {
        let conversationId = UUID()
        try await repository.append(
            ChatItem(conversationId: conversationId, role: "user", content: userText, date: date)
        )
        try await repository.append(
            ChatItem(conversationId: conversationId, role: "assistant", content: assistantText, date: date.addingTimeInterval(1))
        )
        return conversationId
    }

    // MARK: - Delete

    func testDeleteConversationRemovesOnlyThatConversation() async throws {
        for repository in try [makeSwiftDataRepository() as ChatHistoryRepository, InMemoryChatHistoryRepository()] {
            let kept = try await seedConversation(in: repository, userText: "Kept question")
            let deleted = try await seedConversation(in: repository, userText: "Deleted question")

            try await repository.deleteConversation(id: deleted)

            let conversations = try await repository.loadConversations()
            XCTAssertEqual(conversations.map(\.id), [kept])
            let deletedHistory = try await repository.loadHistory(conversationId: deleted)
            XCTAssertTrue(deletedHistory.isEmpty)
            let keptHistory = try await repository.loadHistory(conversationId: kept)
            XCTAssertEqual(keptHistory.count, 2)
        }
    }

    func testDeleteConversationAlsoDropsItsCustomTitle() async throws {
        for repository in try [makeSwiftDataRepository() as ChatHistoryRepository, InMemoryChatHistoryRepository()] {
            let conversationId = try await seedConversation(in: repository, userText: "Original question")
            try await repository.renameConversation(id: conversationId, title: "Wound care")
            try await repository.deleteConversation(id: conversationId)

            // Re-using the id (as a fresh conversation would if it collided) must not inherit
            // the old rename.
            try await repository.append(
                ChatItem(conversationId: conversationId, role: "user", content: "Brand new question")
            )

            let conversations = try await repository.loadConversations()
            XCTAssertEqual(conversations.first?.title, "Brand new question")
            XCTAssertEqual(conversations.first?.hasCustomTitle, false)
        }
    }

    func testDeleteAllConversationsEmptiesTheHistory() async throws {
        for repository in try [makeSwiftDataRepository() as ChatHistoryRepository, InMemoryChatHistoryRepository()] {
            let first = try await seedConversation(in: repository, userText: "First question")
            try await seedConversation(in: repository, userText: "Second question")
            try await repository.renameConversation(id: first, title: "Renamed")

            try await repository.deleteAllConversations()

            let conversations = try await repository.loadConversations()
            XCTAssertTrue(conversations.isEmpty)
            let history = try await repository.loadHistory(conversationId: first)
            XCTAssertTrue(history.isEmpty)
        }
    }

    // MARK: - Rename

    func testRenameOverridesTheDerivedTitle() async throws {
        for repository in try [makeSwiftDataRepository() as ChatHistoryRepository, InMemoryChatHistoryRepository()] {
            let conversationId = try await seedConversation(in: repository, userText: "Câu hỏi đầu tiên")

            try await repository.renameConversation(id: conversationId, title: "  Chăm sóc vết mổ  ")

            let conversations = try await repository.loadConversations()
            XCTAssertEqual(conversations.first?.title, "Chăm sóc vết mổ")
            XCTAssertEqual(conversations.first?.hasCustomTitle, true)
            // The messages themselves are untouched by a rename.
            let history = try await repository.loadHistory(conversationId: conversationId)
            XCTAssertEqual(history.first?.content, "Câu hỏi đầu tiên")
        }
    }

    func testRenamingTwiceKeepsTheLatestTitle() async throws {
        for repository in try [makeSwiftDataRepository() as ChatHistoryRepository, InMemoryChatHistoryRepository()] {
            let conversationId = try await seedConversation(in: repository, userText: "First question")

            try await repository.renameConversation(id: conversationId, title: "First name")
            try await repository.renameConversation(id: conversationId, title: "Second name")

            let conversations = try await repository.loadConversations()
            XCTAssertEqual(conversations.count, 1)
            XCTAssertEqual(conversations.first?.title, "Second name")
        }
    }

    func testBlankRenameRestoresTheDerivedTitle() async throws {
        for repository in try [makeSwiftDataRepository() as ChatHistoryRepository, InMemoryChatHistoryRepository()] {
            let conversationId = try await seedConversation(in: repository, userText: "First question")
            try await repository.renameConversation(id: conversationId, title: "Custom")

            try await repository.renameConversation(id: conversationId, title: "   ")

            let conversations = try await repository.loadConversations()
            XCTAssertEqual(conversations.first?.title, "First question")
            XCTAssertEqual(conversations.first?.hasCustomTitle, false)
        }
    }

    func testRenameOnlyAffectsTheTargetedConversation() async throws {
        for repository in try [makeSwiftDataRepository() as ChatHistoryRepository, InMemoryChatHistoryRepository()] {
            let renamed = try await seedConversation(in: repository, userText: "Renamed question")
            let untouched = try await seedConversation(in: repository, userText: "Untouched question")

            try await repository.renameConversation(id: renamed, title: "Diet plan")

            let byId = Dictionary(uniqueKeysWithValues: try await repository.loadConversations().map { ($0.id, $0) })
            XCTAssertEqual(byId[renamed]?.title, "Diet plan")
            XCTAssertEqual(byId[untouched]?.title, "Untouched question")
        }
    }
}
