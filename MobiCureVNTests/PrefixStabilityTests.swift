import XCTest
@testable import MobiCureVN

/// Asserts that the "stable" half of the system prompt really is stable.
///
/// A prefix KV cache can only reuse a prefix that is **byte-identical** between turns. Before
/// this, "the top of the prompt does not change" was a claim in a comment, and a single stray
/// interpolation — a timestamp, a turn counter, a re-ordered set — would have silently defeated
/// every later caching attempt while looking correct.
///
/// These tests are the contract that makes the caching work worth starting. They are also the
/// cheap half of it: they need no MLX runtime and run in milliseconds.
final class PrefixStabilityTests: XCTestCase {

    /// Built with in-memory stores rather than the defaults, which reach AppConfig's
    /// SwiftData-backed repositories. buildEnrichedPrompt is pure string assembly and needs none
    /// of them. The RAG service still defaults to AppConfig.retriever (the bundled SQLite
    /// index), which prompt building never calls.
    private let orchestrator = MedicalChatOrchestrator(
        llmService: MockLLMService(),
        factStore: SessionFactStore(),
        profileRepository: InMemoryProfileRepository(patientID: UUID()),
        profileUpdateStore: InMemoryProfileUpdateRepository()
    )

    private func context(chunks: [ContextChunk], confidence: Double = 0.8) -> RetrievedContext {
        RetrievedContext(
            chunks: chunks,
            confidenceScore: confidence,
            sources: chunks.map {
                MedicalSource(
                    id: $0.id,
                    title: $0.section,
                    excerpt: String($0.content.prefix(40)),
                    page: 1,
                    documentName: $0.sourceID
                )
            }
        )
    }

    private func chunk(_ id: String, _ text: String) -> ContextChunk {
        ContextChunk(id: id, content: text, section: "Section \(id)", sourceID: "src_\(id)", relevanceScore: 0.9)
    }

    private static let profile = PatientProfile(
        name: "Test Patient",
        age: 62,
        gender: "female",
        diagnosis: "colorectal cancer",
        procedure: "anterior resection",
        recoveryStage: "week 3",
        reportSummary: "",
        careNotes: [],
        warningSigns: [],
        sourceName: "test"
    )

    // MARK: - The prefix must NOT move turn to turn

    func testPrefixIsIdenticalAcrossDifferentQuestions() {
        let ctx = context(chunks: [chunk("a", "Stoma care guidance.")])
        let first = orchestrator.buildEnrichedPrompt(userQuery: "What is a stoma?", context: ctx, history: [])
        let second = orchestrator.buildEnrichedPrompt(userQuery: "How do I shower?", context: ctx, history: [])
        XCTAssertEqual(first.stablePrefix, second.stablePrefix)
    }

    func testPrefixIsIdenticalWhenRetrievedContextChanges() {
        // Retrieval is the single most volatile input. If it reaches the prefix, caching is dead.
        let a = context(chunks: [chunk("a", "Guidance about pouches.")])
        let b = context(chunks: [chunk("b", "Completely different guidance about diet."), chunk("c", "More.")], confidence: 0.42)
        let first = orchestrator.buildEnrichedPrompt(userQuery: "Q", context: a, history: [])
        let second = orchestrator.buildEnrichedPrompt(userQuery: "Q", context: b, history: [])
        XCTAssertEqual(first.stablePrefix, second.stablePrefix)
        XCTAssertNotEqual(first.volatileSuffix, second.volatileSuffix, "context must land in the volatile half")
    }

    func testPrefixIsIdenticalWhenSessionFactsAccumulate() {
        let ctx = context(chunks: [chunk("a", "Text.")])
        let first = orchestrator.buildEnrichedPrompt(userQuery: "Q", context: ctx, history: [], rememberedFacts: nil)
        let second = orchestrator.buildEnrichedPrompt(
            userQuery: "Q", context: ctx, history: [], rememberedFacts: "name: John\nallergy: penicillin"
        )
        XCTAssertEqual(first.stablePrefix, second.stablePrefix)
        XCTAssertNotEqual(first.volatileSuffix, second.volatileSuffix)
    }

    func testPrefixIsIdenticalWhenHistoryGrows() {
        let ctx = context(chunks: [chunk("a", "Text.")])
        let history = [
            ChatMessage(role: "user", content: "earlier question"),
            ChatMessage(role: "assistant", content: "earlier answer"),
        ]
        let first = orchestrator.buildEnrichedPrompt(userQuery: "Q", context: ctx, history: [])
        let second = orchestrator.buildEnrichedPrompt(userQuery: "Q", context: ctx, history: history)
        XCTAssertEqual(first.stablePrefix, second.stablePrefix, "history travels separately, never in the prompt")
    }

    func testPrefixIsIdenticalWhenNoContextWasRetrieved() {
        // The empty-context branch injects an extra instruction; it must go in the volatile half.
        let full = context(chunks: [chunk("a", "Text.")])
        let empty = context(chunks: [])
        let first = orchestrator.buildEnrichedPrompt(userQuery: "Q", context: full, history: [])
        let second = orchestrator.buildEnrichedPrompt(userQuery: "Q", context: empty, history: [])
        XCTAssertEqual(first.stablePrefix, second.stablePrefix)
    }

    func testPrefixIsStableAcrossRepeatedCallsWithIdenticalInput() {
        // Guards against anything time-derived leaking in.
        let ctx = context(chunks: [chunk("a", "Text.")])
        let a = orchestrator.buildEnrichedPrompt(userQuery: "Q", context: ctx, history: [])
        let b = orchestrator.buildEnrichedPrompt(userQuery: "Q", context: ctx, history: [])
        XCTAssertEqual(a.stablePrefix, b.stablePrefix)
        XCTAssertEqual(a.volatileSuffix, b.volatileSuffix)
    }

    // MARK: - The prefix MUST move when its own inputs change

    func testPrefixChangesWithLanguage() {
        let ctx = context(chunks: [chunk("a", "Text.")])
        let english = orchestrator.buildEnrichedPrompt(userQuery: "Q", context: ctx, history: [], responseLanguage: .english)
        let vietnamese = orchestrator.buildEnrichedPrompt(userQuery: "Q", context: ctx, history: [], responseLanguage: .vietnamese)
        XCTAssertNotEqual(english.stablePrefix, vietnamese.stablePrefix,
                          "a cache keyed on the prefix must miss when the answer language changes")
    }

    func testPrefixChangesWithTheConfirmedProfile() {
        let ctx = context(chunks: [chunk("a", "Text.")])
        let without = orchestrator.buildEnrichedPrompt(userQuery: "Q", context: ctx, history: [])
        let with = orchestrator.buildEnrichedPrompt(userQuery: "Q", context: ctx, history: [], confirmedProfile: Self.profile)
        XCTAssertNotEqual(without.stablePrefix, with.stablePrefix)
    }

    // MARK: - Composition

    func testSystemPromptIsThePrefixFollowedByTheSuffix() {
        // Order is part of the contract: the stable half must come first or there is no
        // reusable prefix at all.
        let ctx = context(chunks: [chunk("a", "Text.")])
        let prompt = orchestrator.buildEnrichedPrompt(userQuery: "Q", context: ctx, history: [])
        XCTAssertTrue(prompt.systemPrompt.hasPrefix(prompt.stablePrefix))
        XCTAssertTrue(prompt.systemPrompt.hasSuffix(prompt.volatileSuffix))
    }

    func testTheStableHalfCarriesTheSafetyConstraints() {
        // If the constraints drifted into the volatile half they would still work, but the
        // cacheable prefix would shrink to almost nothing and the optimisation would be moot.
        let ctx = context(chunks: [chunk("a", "Text.")])
        // Case-insensitive on purpose: the exact casing differs depending on whether
        // final/prompt-slimming is merged, and this test is about WHICH HALF the constraints
        // live in, not how they are worded.
        let prefix = orchestrator
            .buildEnrichedPrompt(userQuery: "Q", context: ctx, history: [])
            .stablePrefix
            .lowercased()
        XCTAssertTrue(prefix.contains("licensed physician"))
        XCTAssertTrue(prefix.contains("emergency services"))
    }
}
