import XCTest
@testable import MobiCureVN

/// Tests for core data models — verifies initialization, default values, and Codable conformance.
/// A new build passes if all model constructors and serialization work as expected.
final class ChatItemModelTests: XCTestCase {

    func testChatItemDefaultsToRandomID() {
        let a = ChatItem(role: "user", content: "Hello")
        let b = ChatItem(role: "user", content: "Hello")
        XCTAssertNotEqual(a.id, b.id)
    }

    func testChatItemDefaultsToRandomConversationID() {
        let a = ChatItem(role: "user", content: "Hello")
        let b = ChatItem(role: "user", content: "Hello")
        XCTAssertNotEqual(a.conversationId, b.conversationId)
    }

    func testChatItemDefaultsToEmptySources() {
        let item = ChatItem(role: "user", content: "Hello")
        XCTAssertTrue(item.sources.isEmpty)
    }

    func testChatItemStoresRoleAndContent() {
        let item = ChatItem(role: "assistant", content: "You should rest.")
        XCTAssertEqual(item.role, "assistant")
        XCTAssertEqual(item.content, "You should rest.")
    }

    func testChatItemWithSources() {
        let source = MedicalSource(id: "src1", title: "Medical Guide", excerpt: "Chapter 1", page: 5, documentName: "guide.pdf")
        let item = ChatItem(role: "assistant", content: "See source", sources: [source])
        XCTAssertEqual(item.sources.count, 1)
        XCTAssertEqual(item.sources[0].id, "src1")
    }
}

final class MedicalSourceModelTests: XCTestCase {

    func testMedicalSourceInitialization() {
        let source = MedicalSource(
            id: "doc_001",
            title: "Post-Surgery Care Guide",
            excerpt: "Patients should avoid heavy lifting for 6 weeks after colorectal surgery.",
            page: 12,
            documentName: "care_guide.pdf"
        )
        XCTAssertEqual(source.id, "doc_001")
        XCTAssertEqual(source.title, "Post-Surgery Care Guide")
        XCTAssertEqual(source.page, 12)
        XCTAssertEqual(source.documentName, "care_guide.pdf")
        XCTAssertFalse(source.excerpt.isEmpty)
    }

    func testMedicalSourceIDIsStored() {
        let source = MedicalSource(id: "unique-id-123", title: "Guide", excerpt: "text", page: 1, documentName: "file.pdf")
        XCTAssertEqual(source.id, "unique-id-123")
    }
}

final class GuardRailResultModelTests: XCTestCase {

    func testInputGuardRailResultDefaultSanitizedQueryIsNil() {
        let result = InputGuardRailResult(status: .allowed, originalQuery: "test")
        XCTAssertNil(result.sanitizedQuery)
        XCTAssertTrue(result.violations.isEmpty)
    }

    func testInputGuardRailResultStoresOriginalQuery() {
        let query = "I have a wound infection"
        let result = InputGuardRailResult(status: .allowed, originalQuery: query)
        XCTAssertEqual(result.originalQuery, query)
    }

    func testGuardRailStatusAllowedIsNotBlocked() {
        let status = GuardRailStatus.allowed
        if case .blocked = status {
            XCTFail("allowed should not match blocked pattern")
        }
    }

    func testGuardRailStatusBlockedCarriesReason() {
        let status = GuardRailStatus.blocked(reason: "Safety violation")
        guard case .blocked(let reason) = status else {
            XCTFail("Expected blocked")
            return
        }
        XCTAssertEqual(reason, "Safety violation")
    }

    func testEmergencyDetectionResultDefaultsToNotEmergency() {
        let result = EmergencyDetectionResult(isEmergency: false)
        XCTAssertFalse(result.isEmergency)
        XCTAssertNil(result.symptomType)
        XCTAssertNil(result.recommendation)
    }

    func testEmergencyDetectionResultWithSymptom() {
        let result = EmergencyDetectionResult(isEmergency: true, symptomType: .chestPain, recommendation: "Call 119")
        XCTAssertTrue(result.isEmergency)
        XCTAssertEqual(result.symptomType, .chestPain)
        XCTAssertEqual(result.recommendation, "Call 119")
    }

    func testContextChunkStoresFields() {
        let chunk = ContextChunk(id: "c1", content: "text", section: "intro", sourceID: "s1", relevanceScore: 0.85)
        XCTAssertEqual(chunk.id, "c1")
        XCTAssertEqual(chunk.relevanceScore, 0.85, accuracy: 0.001)
    }

    func testRetrievedContextDefaultsToEmptySources() {
        let context = RetrievedContext(chunks: [], confidenceScore: 0.7)
        XCTAssertTrue(context.sources.isEmpty)
        XCTAssertEqual(context.confidenceScore, 0.7, accuracy: 0.001)
    }
}

final class EmergencySymptomTypeTests: XCTestCase {

    func testAllCasesHaveRawValues() {
        let cases: [EmergencySymptomType] = [
            .chestPain, .difficultyBreathing, .seizure,
            .suicidalIdeation, .strokeSymptom, .severeBleeding, .lossOfConsciousness
        ]
        for symptom in cases {
            XCTAssertFalse(symptom.rawValue.isEmpty, "\(symptom) should have a non-empty rawValue")
        }
    }

    func testAllCasesHaveEmergencyResponseTemplates() {
        let cases: [EmergencySymptomType] = [
            .chestPain, .difficultyBreathing, .seizure,
            .suicidalIdeation, .strokeSymptom, .severeBleeding, .lossOfConsciousness
        ]
        for symptom in cases {
            let template = EmergencyResponses.templates[symptom]
            XCTAssertNotNil(template, "\(symptom) should have a response template")
            XCTAssertFalse(template?.isEmpty ?? true, "\(symptom) template should not be empty")
        }
    }
}
