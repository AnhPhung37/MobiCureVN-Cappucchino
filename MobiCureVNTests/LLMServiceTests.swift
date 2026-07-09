import XCTest
#if canImport(MLXLLM)
import MLXLMCommon
#endif
@testable import MobiCureVN

/// Tests for LLMService's prompt/message construction.
///
/// Regression coverage for a bug where the system prompt (containing the
/// "respond only in Vietnamese/English" directive) was flattened into a single
/// `.user` chat turn instead of a real `.system` role. MLX's chat-template
/// generator (`Chat.generate(from:)`) turns `UserInput(prompt: String)` into
/// exactly one `{"role": "user", ...}` message, so any instructions embedded in
/// that string are not treated as a system-level directive by the model.
#if canImport(MLXLLM)
final class LLMServiceTests: XCTestCase {

    private var sut: LLMService!

    override func setUp() {
        super.setUp()
        sut = LLMService(modelPath: "/nonexistent/path", useMock: true)
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    func testSystemPromptBecomesASystemRoleMessage() {
        let messages = sut.buildChatMessages(
            system: "Respond ONLY in Vietnamese.",
            history: [],
            user: "What should I eat for a cold?"
        )

        let systemMessages = messages.filter { $0.role == .system }
        XCTAssertEqual(systemMessages.count, 1, "system prompt must produce exactly one .system message")
        XCTAssertEqual(systemMessages.first?.content, "Respond ONLY in Vietnamese.")

        // The language directive must not be smuggled into a .user message's content.
        for message in messages where message.role == .user {
            XCTAssertFalse(
                message.content.contains("Respond ONLY in Vietnamese"),
                "language directive leaked into a user-role message: \(message.content)"
            )
        }
    }

    func testHistoryRolesAreMappedToRealChatRoles() {
        let history = [
            ChatMessage(role: "user", content: "Hi"),
            ChatMessage(role: "assistant", content: "Hello, how can I help?")
        ]

        let messages = sut.buildChatMessages(system: "", history: history, user: "Follow up question")

        XCTAssertEqual(messages.map(\.role), [.user, .assistant, .user])
        XCTAssertEqual(messages.map(\.content), ["Hi", "Hello, how can I help?", "Follow up question"])
    }

    func testEmptySystemPromptProducesNoSystemMessage() {
        let messages = sut.buildChatMessages(system: "   ", history: [], user: "Hello")
        XCTAssertTrue(messages.allSatisfy { $0.role != .system })
    }

    func testUserMessageIsAlwaysLastAndUserRole() {
        let history = [ChatMessage(role: "assistant", content: "Previous answer")]
        let messages = sut.buildChatMessages(system: "sys", history: history, user: "Latest question")

        XCTAssertEqual(messages.last?.role, .user)
        XCTAssertEqual(messages.last?.content, "Latest question")
    }
}
#endif
