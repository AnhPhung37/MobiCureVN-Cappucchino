import XCTest
@testable import MobiCureVN

/// `maxTokens` 1024 → 512 halves worst-case decode, and makes a cut-off answer more likely —
/// Vietnamese costs more tokens per idea than English on several tokenizers. The model ends an
/// answer with the consult-your-provider disclaimer, so a cut answer is precisely the one missing
/// it. These tests pin that a truncation is reported by the backend contract and never reaches the
/// patient silently.
@MainActor
final class GenerationCompletionTests: XCTestCase {

    func testABackendThatCannotReportCompletionSaysUnknown() async {
        var events: [LLMStreamEvent] = []
        for await event in TextOnlyLLM().streamEvents(request: LLMRequest(userMessage: "q")) {
            events.append(event)
        }
        XCTAssertEqual(events, [.text("a"), .text("b"), .completed(.unknown)])
    }

    func testATruncatedAnswerSaysSoAndRestoresTheDisclaimer() {
        let english = MedicalChatOrchestrator.completingTruncatedAnswer(
            "Keep the wound clean and", completion: .truncated, language: .english
        )
        XCTAssertTrue(english.hasPrefix("Keep the wound clean and"))
        XCTAssertTrue(english.contains("cut off"))
        XCTAssertTrue(english.contains("healthcare provider"))

        let vietnamese = MedicalChatOrchestrator.completingTruncatedAnswer(
            "Giữ vết mổ sạch và", completion: .truncated, language: .vietnamese
        )
        XCTAssertTrue(vietnamese.hasPrefix("Giữ vết mổ sạch và"))
        XCTAssertTrue(vietnamese.contains("bị cắt"))
        XCTAssertTrue(vietnamese.contains("nhân viên y tế"))
    }

    func testAFinishedOrUnreportedAnswerIsLeftAlone() {
        for completion in [LLMCompletion.finished, .unknown] {
            XCTAssertEqual(
                MedicalChatOrchestrator.completingTruncatedAnswer("Done.", completion: completion, language: .english),
                "Done."
            )
        }
    }

    func testTheVietnameseNoticeDoesNotTripTheLanguageDriftCheck() {
        // ChatService falls back to translation when a Vietnamese answer carries English runs; the
        // notice must not be what triggers it.
        let answer = MedicalChatOrchestrator.completingTruncatedAnswer(
            "Giữ vết mổ sạch và khô, thay băng mỗi ngày.", completion: .truncated, language: .vietnamese
        )
        XCTAssertEqual(LanguageValidationService().checkGeneratedLanguage(answer, expected: .vietnamese), .ok)
    }

    func testShippedGenerationDefaults() {
        XCTAssertEqual(InferenceTuning.defaults.generation.maxTokens, 512)
        XCTAssertNil(
            InferenceTuning.defaults.generation.prefillStepSize,
            "mlx-swift-lm already defaults to 512; shipping 512 changed nothing but the claim"
        )
    }
}

/// Reports text only, so it inherits the protocol's default `streamEvents`.
private nonisolated final class TextOnlyLLM: LLMServiceProtocol {
    nonisolated func stream(request: LLMRequest) -> AsyncStream<String> {
        AsyncStream { continuation in
            continuation.yield("a")
            continuation.yield("b")
            continuation.finish()
        }
    }
}
