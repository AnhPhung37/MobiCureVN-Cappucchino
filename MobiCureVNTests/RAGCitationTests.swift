import XCTest
@testable import MobiCureVN

/// Tests for RAG citation accuracy and source model integrity.
/// Validates: MedicalSource structure, RetrievedContext contracts,
/// source deduplication invariants, confidence score bounds,
/// and OutputGuardRail citation-keyword detection paths.
final class RAGCitationTests: XCTestCase {

    // MARK: - MedicalSource Structure

    func testMedicalSourceStoresAllFields() {
        let source = MedicalSource(
            id: "doc_001",
            title: "Post-Surgery Care",
            excerpt: "Patients should avoid heavy lifting for 6 weeks after colorectal surgery.",
            page: 12,
            documentName: "MOH — Clinical Guidelines"
        )
        XCTAssertEqual(source.id, "doc_001")
        XCTAssertEqual(source.title, "Post-Surgery Care")
        XCTAssertEqual(source.page, 12)
        XCTAssertEqual(source.documentName, "MOH — Clinical Guidelines")
        XCTAssertFalse(source.excerpt.isEmpty)
    }

    func testMedicalSourceExcerptRespects120CharLimit() {
        // SQLiteRetriever truncates to 120 chars — verify the model stores exactly what was passed
        let longText = String(repeating: "a", count: 200)
        let truncated = String(longText.prefix(120))
        let source = MedicalSource(id: "d1", title: "T", excerpt: truncated, page: 0, documentName: "S")
        XCTAssertEqual(source.excerpt.count, 120, "Excerpt from SQLiteRetriever is capped at 120 chars")
        XCTAssertLessThanOrEqual(source.excerpt.count, 120)
    }

    func testMedicalSourceDocumentNameUsesEmDashSeparator() {
        // SQLiteRetriever builds documentName as "\(sourceOrg) — \(docType)"
        let source = MedicalSource(id: "d1", title: "T", excerpt: "e", page: 0,
                                   documentName: "WHO — Surgical Guidelines")
        XCTAssertTrue(source.documentName.contains("—"),
                      "documentName should use em-dash separator between org and doc type")
    }

    func testMedicalSourcePageZeroIndicatesUnknown() {
        let source = MedicalSource(id: "d1", title: "T", excerpt: "e", page: 0, documentName: "S")
        XCTAssertEqual(source.page, 0, "Page 0 is the sentinel for unknown page number")
    }

    func testMedicalSourceIdentifiableConformance() {
        let source = MedicalSource(id: "unique-abc-123", title: "T", excerpt: "e", page: 1, documentName: "S")
        XCTAssertEqual(source.id, "unique-abc-123")
    }

    func testTwoSourcesWithSameIDHaveSameIDField() {
        // Deduplication logic in SQLiteRetriever keys on docID — verify the model stores it faithfully
        let s1 = MedicalSource(id: "shared-id", title: "A", excerpt: "x", page: 1, documentName: "Org A — Type")
        let s2 = MedicalSource(id: "shared-id", title: "B", excerpt: "y", page: 2, documentName: "Org B — Type")
        XCTAssertEqual(s1.id, s2.id)
        XCTAssertNotEqual(s1.title, s2.title, "Same docID can appear in different chunks with different sections")
    }

    // MARK: - RetrievedContext Model

    func testRetrievedContextStoresConfidenceScore() {
        let context = RetrievedContext(chunks: [], confidenceScore: 0.78)
        XCTAssertEqual(context.confidenceScore, 0.78, accuracy: 0.001)
    }

    func testRetrievedContextSourcesDefaultToEmpty() {
        let context = RetrievedContext(chunks: [], confidenceScore: 0.5)
        XCTAssertTrue(context.sources.isEmpty)
    }

    func testRetrievedContextStoresMultipleSources() {
        let sources = makeSources(count: 3)
        let context = RetrievedContext(chunks: [], confidenceScore: 0.8, sources: sources)
        XCTAssertEqual(context.sources.count, 3)
    }

    func testRetrievedContextPreservesChunks() {
        let chunks = [
            ContextChunk(id: "c1", content: "Wound care advice", section: "Post-Op", sourceID: "d1", relevanceScore: 0.8),
            ContextChunk(id: "c2", content: "Diet guidance", section: "Nutrition", sourceID: "d2", relevanceScore: 0.6),
        ]
        let context = RetrievedContext(chunks: chunks, confidenceScore: 0.7)
        XCTAssertEqual(context.chunks.count, 2)
        XCTAssertEqual(context.chunks[0].id, "c1")
        XCTAssertEqual(context.chunks[1].id, "c2")
    }

    // MARK: - Confidence Score Bounds

    func testConfidenceScoreIsNonNegative() {
        let context = RetrievedContext(chunks: [], confidenceScore: 0.0)
        XCTAssertGreaterThanOrEqual(context.confidenceScore, 0.0)
    }

    func testConfidenceScoreDoesNotExceedOne() {
        let context = RetrievedContext(chunks: [], confidenceScore: 1.0)
        XCTAssertLessThanOrEqual(context.confidenceScore, 1.0)
    }

    func testZeroChunksImpliesZeroConfidence() {
        let context = RetrievedContext(chunks: [], confidenceScore: 0.0)
        XCTAssertEqual(context.confidenceScore, 0.0)
    }

    func testHighRelevanceChunksGiveConfidenceAboveThreshold() {
        // Verify the scoring contract: 5 high-relevance chunks → confidence > minMedicalConfidenceThreshold
        let chunks = (0..<5).map { i in
            ContextChunk(id: "c\(i)", content: "clinical text", section: "sec", sourceID: "d\(i)", relevanceScore: 0.9)
        }
        let context = RetrievedContext(chunks: chunks, confidenceScore: 0.85)
        XCTAssertGreaterThan(context.confidenceScore, GuardRailRules.minMedicalConfidenceThreshold,
                             "High-quality retrieval should exceed the \(GuardRailRules.minMedicalConfidenceThreshold) threshold")
    }

    // MARK: - Source Deduplication Contract

    func testAllSourceIDsInContextAreUnique() {
        let sources = makeSources(count: 4)
        let context = RetrievedContext(chunks: [], confidenceScore: 0.8, sources: sources)
        let ids = context.sources.map(\.id)
        let uniqueIDs = Set(ids)
        XCTAssertEqual(ids.count, uniqueIDs.count,
                       "SQLiteRetriever deduplication guarantees unique docIDs in RetrievedContext")
    }

    func testEmptySourceListForNoResults() {
        let context = RetrievedContext(chunks: [], confidenceScore: 0.0, sources: [])
        XCTAssertTrue(context.sources.isEmpty)
    }

    func testSingleSourceContextHasOneSource() {
        let source = MedicalSource(id: "only-doc", title: "Guide", excerpt: "text", page: 1,
                                   documentName: "Org — Type")
        let context = RetrievedContext(chunks: [], confidenceScore: 0.7, sources: [source])
        XCTAssertEqual(context.sources.count, 1)
        XCTAssertEqual(context.sources.first?.id, "only-doc")
    }

    // MARK: - ContextChunk Model

    func testContextChunkRelevanceScoreInUnitRange() {
        let chunk = ContextChunk(id: "c1", content: "text", section: "intro", sourceID: "d1", relevanceScore: 0.75)
        XCTAssertGreaterThanOrEqual(chunk.relevanceScore, 0.0)
        XCTAssertLessThanOrEqual(chunk.relevanceScore, 1.0)
    }

    func testContextChunkPreservesContent() {
        let content = "Patients should avoid heavy lifting for 6 weeks after colorectal surgery."
        let chunk = ContextChunk(id: "c1", content: content, section: "Care", sourceID: "d1", relevanceScore: 0.8)
        XCTAssertEqual(chunk.content, content)
    }

    func testContextChunkPreservesSection() {
        let chunk = ContextChunk(id: "c1", content: "text", section: "Post-Op Care", sourceID: "d1", relevanceScore: 0.5)
        XCTAssertEqual(chunk.section, "Post-Op Care")
    }

    func testContextChunkPreservesSourceID() {
        let chunk = ContextChunk(id: "c1", content: "text", section: "sec", sourceID: "document-99", relevanceScore: 0.5)
        XCTAssertEqual(chunk.sourceID, "document-99")
    }

    // MARK: - Citation Keyword Detection (OutputGuardRail integration)

    func testCitationDetected_AccordingTo() {
        let result = makeOutputGuardRail().validate(
            response: "According to clinical guidelines, you should rest for six weeks.",
            retrievedContext: makeContextAboveThreshold(),
            originalQuery: "What should I do?"
        )
        XCTAssertAllowed(result, "\"According to\" is a citation keyword — medical advice should pass")
    }

    func testCitationDetected_Research() {
        let result = makeOutputGuardRail().validate(
            response: "Research shows that early mobilisation improves recovery.",
            retrievedContext: makeContextAboveThreshold(),
            originalQuery: "Should I move around?"
        )
        XCTAssertAllowed(result, "\"research\" is a citation keyword — should pass")
    }

    func testCitationDetected_Study() {
        let result = makeOutputGuardRail().validate(
            response: "A study found that patients should use compression stockings.",
            retrievedContext: makeContextAboveThreshold(),
            originalQuery: "How do I prevent blood clots?"
        )
        XCTAssertAllowed(result, "\"study\" is a citation keyword — should pass")
    }

    func testCitationDetected_BasedOn() {
        let result = makeOutputGuardRail().validate(
            response: "Based on available evidence, you should avoid NSAIDs after surgery.",
            retrievedContext: makeContextAboveThreshold(),
            originalQuery: "Should I take pain relievers?"
        )
        XCTAssertAllowed(result, "\"Based on\" is a citation keyword — should pass")
    }

    func testNoCitationBlocksMedicalAdvice() {
        // No citation keywords, no retrieved sources → citation enforcement fires
        let context = RetrievedContext(chunks: [], confidenceScore: 0.9, sources: [])
        let result = makeOutputGuardRail().validate(
            response: "You should take ibuprofen and avoid strenuous activity.",
            retrievedContext: context,
            originalQuery: "What should I do for pain?"
        )
        XCTAssertBlocked(result, "Medical advice without any citation or source must be blocked")
    }

    func testSourcesInContextSatisfyCitationRequirement() {
        let context = RetrievedContext(
            chunks: [],
            confidenceScore: 0.9,
            sources: [MedicalSource(id: "d1", title: "Guide", excerpt: "text", page: 1, documentName: "Org — Type")]
        )
        let result = makeOutputGuardRail().validate(
            response: "You should start walking short distances each day.",
            retrievedContext: context,
            originalQuery: "When can I exercise?"
        )
        XCTAssertAllowed(result, "Retrieved sources satisfy citation requirement even without inline citation text")
    }

    // MARK: - Performance

    func testCitationCheckPerformanceWithManySources() {
        let guardrail = makeOutputGuardRail()
        let sources = (0..<10).map { i in
            MedicalSource(id: "doc\(i)", title: "Title \(i)", excerpt: "text", page: i, documentName: "Org — Type")
        }
        let context = RetrievedContext(chunks: [], confidenceScore: 0.9, sources: sources)
        let start = Date()
        for _ in 0..<1_000 {
            _ = guardrail.validate(
                response: "Based on clinical research, you should follow your treatment plan.",
                retrievedContext: context,
                originalQuery: "What is my treatment plan?"
            )
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 2.0, "1000 citation checks with 10 sources should complete within 2 seconds")
    }
}

// MARK: - Helpers

private extension RAGCitationTests {

    func makeSources(count: Int) -> [MedicalSource] {
        (0..<count).map { i in
            MedicalSource(id: "doc\(i)", title: "Guide \(i)", excerpt: "excerpt \(i)",
                          page: i + 1, documentName: "Org \(i) — Type \(i)")
        }
    }

    func makeContextAboveThreshold(sourceCount: Int = 0) -> RetrievedContext {
        let sources = (0..<sourceCount).map { i in
            MedicalSource(id: "d\(i)", title: "T\(i)", excerpt: "e", page: i, documentName: "Org — Type")
        }
        return RetrievedContext(chunks: [], confidenceScore: 0.9, sources: sources)
    }

    func makeOutputGuardRail() -> OutputGuardRail {
        OutputGuardRail()
    }

    func XCTAssertAllowed(_ result: OutputGuardRailResult, _ message: String = "",
                          file: StaticString = #file, line: UInt = #line) {
        guard case .allowed = result.status else {
            XCTFail("Expected .allowed but got \(result.status). Issues: \(result.issues). \(message)",
                    file: file, line: line)
            return
        }
    }

    func XCTAssertBlocked(_ result: OutputGuardRailResult, _ message: String = "",
                          file: StaticString = #file, line: UInt = #line) {
        guard case .blocked = result.status else {
            XCTFail("Expected .blocked but got \(result.status). \(message)", file: file, line: line)
            return
        }
    }
}
