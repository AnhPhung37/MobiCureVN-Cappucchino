import XCTest
@testable import MobiCureVN

/// Tests for OutputGuardRail — validates LLM responses before streaming to the user.
/// A new build passes if the four checks (citation, confidence, hallucination, unsafe
/// dosage) fire correctly and allowed responses pass cleanly. Emergency detection is the
/// orchestrator's job (it runs before the LLM), so it is covered by EmergencyDetectorTests.
@MainActor
final class OutputGuardRailTests: XCTestCase {

    private var sut: OutputGuardRail!

    override func setUp() {
        super.setUp()
        sut = OutputGuardRail()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - Model Accuracy: Safe Responses Pass Through

    func testAllowsSafeResponseWithHighConfidenceAndSources() {
        let context = makeContext(confidence: 0.85, sourceCount: 1)
        let result = sut.validate(
            response: "You should rest and avoid heavy lifting after surgery.",
            retrievedContext: context
        )
        XCTAssertAllowed(result)
    }

    func testAllowsResponseWithInlineCitationKeyword_AccordingTo() {
        let context = makeContext(confidence: 0.8)
        let result = sut.validate(
            response: "According to clinical guidelines, you should rest for at least six weeks.",
            retrievedContext: context
        )
        XCTAssertAllowed(result)
    }

    func testAllowsResponseWithCitationKeyword_BasedOn() {
        let context = makeContext(confidence: 0.8)
        let result = sut.validate(
            response: "Based on current research, you should avoid alcohol after surgery.",
            retrievedContext: context
        )
        XCTAssertAllowed(result)
    }

    func testAllowsResponseWithCitationKeyword_Study() {
        let context = makeContext(confidence: 0.8)
        let result = sut.validate(
            response: "A study found that early mobilisation improves recovery outcomes.",
            retrievedContext: context
        )
        XCTAssertAllowed(result)
    }

    func testAllowsNonAdviceResponseWithoutSources() {
        // No advice verbs → citation + confidence checks are skipped
        let context = makeContext(confidence: 0.2)
        let result = sut.validate(
            response: "Post-operative care involves monitoring the wound for signs of infection.",
            retrievedContext: context
        )
        XCTAssertTrue(result.issues.isEmpty)
    }

    func testAllowedResultPreservesOriginalResponse() {
        let context = makeContext(confidence: 0.9, sourceCount: 1)
        let response = "Based on your recovery plan, you should walk short distances daily."
        let result = sut.validate(
            response: response,
            retrievedContext: context
        )
        XCTAssertAllowed(result)
        XCTAssertEqual(result.originalResponse, response)
    }

    // MARK: - Result Shape

    func testBlockedResultAlwaysPreservesOriginalResponse() {
        let context = makeContext(confidence: 0.9)
        let response = "This treatment will definitely cure your infection."
        let result = sut.validate(
            response: response,
            retrievedContext: context
        )
        XCTAssertEqual(result.originalResponse, response)
    }

    // MARK: - Guard Rail: Citation Enforcement (Check 2)

    func testBlocksMedicalAdviceWithNoCitationsAndNoSources() {
        let context = makeContext(confidence: 0.8, sourceCount: 0)
        let result = sut.validate(
            response: "You should take ibuprofen for the pain.",
            retrievedContext: context
        )
        XCTAssertBlocked(result)
        XCTAssertFalse(result.issues.filter { $0.contains("citation") }.isEmpty)
    }

    func testAllowsMedicalAdviceWithRetrievedSources() {
        let context = makeContext(confidence: 0.8, sourceCount: 1)
        let result = sut.validate(
            response: "You should use analgesics as directed.",
            retrievedContext: context
        )
        XCTAssertAllowed(result)
    }

    func testCitationBlockFilteredResponseContainsWarning() {
        let context = makeContext(confidence: 0.8, sourceCount: 0)
        let result = sut.validate(
            response: "Try using compression bandages.",
            retrievedContext: context
        )
        if case .blocked = result.status {
            let filtered = result.filteredResponse ?? ""
            XCTAssertTrue(
                filtered.contains("Important") || filtered.contains("healthcare provider"),
                "Citation-block filtered response should contain a warning"
            )
        }
    }

    // MARK: - Guard Rail: Confidence Threshold (Check 3)

    func testBlocksLowConfidenceMedicalAdvice() {
        // Source present (passes citation), but confidence below threshold
        let context = makeContext(confidence: 0.3, sourceCount: 1)
        let result = sut.validate(
            response: "You should apply ice to reduce swelling.",
            retrievedContext: context
        )
        XCTAssertBlocked(result)
    }

    func testLowConfidenceFilteredResponseContainsLimitationWarning() {
        let context = makeContext(confidence: 0.3, sourceCount: 1)
        let result = sut.validate(
            response: "You should apply ice to reduce swelling.",
            retrievedContext: context
        )
        if case .blocked = result.status {
            XCTAssertTrue(result.filteredResponse?.contains("Limitation") ?? false,
                          "Low-confidence filtered response should include Limitation warning")
        }
    }

    func testHighConfidencePassesThreshold() {
        let context = makeContext(confidence: 0.9, sourceCount: 1)
        let result = sut.validate(
            response: "You should follow the prescribed treatment plan.",
            retrievedContext: context
        )
        XCTAssertAllowed(result)
    }

    func testConfidenceScoreStoredOnResult() {
        let context = makeContext(confidence: 0.75, sourceCount: 1)
        let result = sut.validate(
            response: "According to guidelines, rest is important.",
            retrievedContext: context
        )
        XCTAssertEqual(result.confidenceScore, 0.75, accuracy: 0.001)
    }

    // MARK: - Guard Rail: Hallucination Detection (Check 4)

    func testBlocksHallucination_WillDefinitely() {
        let context = makeContext(confidence: 0.9, sourceCount: 1)
        let result = sut.validate(
            response: "This treatment will definitely cure your infection within a day.",
            retrievedContext: context
        )
        XCTAssertBlocked(result)
        XCTAssertFalse(result.issues.filter { $0.contains("Hallucinated") }.isEmpty)
    }

    func testBlocksHallucination_100PercentEffective() {
        let context = makeContext(confidence: 0.9, sourceCount: 1)
        let result = sut.validate(
            response: "This antibiotic is 100% effective against post-surgical infections.",
            retrievedContext: context
        )
        XCTAssertBlocked(result)
    }

    func testBlocksHallucination_Miraculous() {
        let context = makeContext(confidence: 0.9, sourceCount: 1)
        let result = sut.validate(
            response: "This miraculous remedy will heal your wound overnight.",
            retrievedContext: context
        )
        XCTAssertBlocked(result)
    }

    func testBlocksHallucination_GuaranteedTo() {
        let context = makeContext(confidence: 0.9, sourceCount: 1)
        let result = sut.validate(
            response: "This is guaranteed to relieve your pain in one hour.",
            retrievedContext: context
        )
        XCTAssertBlocked(result)
    }

    func testHallucinatedClaimsAreReplacedInFilteredResponse() {
        let context = makeContext(confidence: 0.9, sourceCount: 1)
        let result = sut.validate(
            response: "This treatment will definitely cure your condition.",
            retrievedContext: context
        )
        XCTAssertTrue(
            result.filteredResponse?.contains("[removed") ?? false,
            "Hallucinated claim should be replaced with [removed: ...] marker"
        )
    }

    // MARK: - Guard Rail: Unsafe Dosage Detection (Check 5)

    func testBlocksUnsafeDosage_Ibuprofen1000mg() {
        let context = makeContext(confidence: 0.9, sourceCount: 1)
        let result = sut.validate(
            response: "Take ibuprofen 1000mg for pain relief.",
            retrievedContext: context
        )
        XCTAssertBlocked(result)
        XCTAssertFalse(result.issues.filter { $0.contains("dosage") }.isEmpty)
    }

    func testBlocksUnsafeDosage_MaximumDose() {
        let context = makeContext(confidence: 0.9, sourceCount: 1)
        let result = sut.validate(
            response: "You can take the maximum dose for faster recovery.",
            retrievedContext: context
        )
        XCTAssertBlocked(result)
    }

    func testBlocksUnsafeDosage_TakeAll() {
        let context = makeContext(confidence: 0.9, sourceCount: 1)
        let result = sut.validate(
            response: "Take all the pills if the pain persists.",
            retrievedContext: context
        )
        XCTAssertBlocked(result)
    }

    func testUnsafeDosageReplacedInFilteredResponse() {
        let context = makeContext(confidence: 0.9, sourceCount: 1)
        let result = sut.validate(
            response: "Based on research, take ibuprofen 1000mg with food.",
            retrievedContext: context
        )
        XCTAssertTrue(
            result.filteredResponse?.contains("[dosage information removed") ?? false,
            "Unsafe dosage should be replaced with removal marker"
        )
    }

    // MARK: - Performance

    func testValidationPerformanceWithHighConfidenceContext() {
        let context = makeContext(confidence: 0.9, sourceCount: 3)
        let response = "Based on your treatment plan, you should follow the doctor's advice carefully."
        let start = Date()
        for _ in 0..<500 {
            _ = sut.validate(response: response, retrievedContext: context)
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 2.0, "500 allowed-path validations should complete within 2 seconds")
    }

    func testValidationPerformanceWithHallucinationScan() {
        // Worst-case path: all 8 hallucination regex patterns are evaluated before passing
        let context = makeContext(confidence: 0.9, sourceCount: 1)
        let response = "According to studies, rest is recommended for post-surgical recovery and wound healing."
        let start = Date()
        for _ in 0..<500 {
            _ = sut.validate(response: response, retrievedContext: context)
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 2.0, "500 hallucination-scan validations should complete within 2 seconds")
    }
}

// MARK: - Helpers

private extension OutputGuardRailTests {

    func makeContext(confidence: Double, sourceCount: Int = 0) -> RetrievedContext {
        let sources = (0..<sourceCount).map { i in
            MedicalSource(
                id: "doc\(i)",
                title: "Medical Guide \(i)",
                excerpt: "Excerpt from medical guide \(i).",
                page: i + 1,
                documentName: "WHO — Clinical Guidelines"
            )
        }
        return RetrievedContext(chunks: [], confidenceScore: confidence, sources: sources)
    }

    func XCTAssertAllowed(_ result: OutputGuardRailResult, file: StaticString = #file, line: UInt = #line) {
        guard case .allowed = result.status else {
            XCTFail("Expected .allowed but got \(result.status). Issues: \(result.issues)", file: file, line: line)
            return
        }
    }

    func XCTAssertBlocked(_ result: OutputGuardRailResult, file: StaticString = #file, line: UInt = #line) {
        guard case .blocked = result.status else {
            XCTFail("Expected .blocked but got \(result.status)", file: file, line: line)
            return
        }
    }
}
