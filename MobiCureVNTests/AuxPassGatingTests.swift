import XCTest
@testable import MobiCureVN

/// The two post-answer passes (`SessionFactExtractor`, `ProfileUpdateExtractor`) each run a
/// full on-device generation. They do not delay the current answer — both run after `.final`
/// is yielded — but they hold the single `ModelContainer`, so an ungated pass makes the user's
/// NEXT message queue behind a generation that was never going to return anything.
///
/// `SessionFactExtractor` was already gated; `ProfileUpdateExtractor` was not, and ran on every
/// turn including plain questions. These tests pin the shared predicate both now use.
final class AuxPassGatingTests: XCTestCase {

    private func gates(_ text: String) -> Bool {
        SessionFactExtractor.statesDurableFact(text)
    }

    /// A profile with nothing on file — the state where the extractor has the most to
    /// propose, so gating it here is the strongest form of the assertion.
    private static let blankProfile = PatientProfile(
        name: "",
        age: 0,
        gender: "",
        diagnosis: "",
        procedure: "",
        recoveryStage: "",
        reportSummary: "",
        careNotes: [],
        warningSigns: [],
        sourceName: "test"
    )

    // MARK: - Turns that must SKIP the LLM passes

    func testAPlainEnglishQuestionStatesNoDurableFact() {
        XCTAssertFalse(gates("What is a stoma?"))
        XCTAssertFalse(gates("How often should the pouch be changed?"))
        XCTAssertFalse(gates("When does recovery usually finish?"))
    }

    func testAPlainVietnameseQuestionStatesNoDurableFact() {
        XCTAssertFalse(gates("Hậu môn nhân tạo là gì?"))
        XCTAssertFalse(gates("Khi nào nên tái khám?"))
    }

    func testGreetingsAndEmptyTurnsSkip() {
        XCTAssertFalse(gates("hello"))
        XCTAssertFalse(gates("thanks!"))
        XCTAssertFalse(gates(""))
    }

    // MARK: - Turns that must RUN the LLM passes

    func testEnglishSelfDisclosureIsCaught() {
        XCTAssertTrue(gates("I am 62 years old"))
        XCTAssertTrue(gates("My surgery was three weeks ago"))
        XCTAssertTrue(gates("I have an allergy to penicillin"))
    }

    func testVietnameseSelfDisclosureIsCaught() {
        XCTAssertTrue(gates("Tôi 62 tuổi"))
        XCTAssertTrue(gates("Tôi bị dị ứng với penicillin"))
        XCTAssertTrue(gates("Mình vừa mổ tuần trước"))
    }

    func testClinicalSelfReportWithoutAPronounIsCaught() {
        XCTAssertTrue(gates("Diagnosed with stage 2 rectal cancer last month"))
        XCTAssertTrue(gates("Taking metformin twice daily"))
    }

    // MARK: - The gate is shared, not duplicated

    func testBothPassesAgreeOnWhatCountsAsADisclosure() async {
        // Two gates drifting apart would be worse than one: a turn could update the session
        // store but never the profile, or the reverse. ProfileUpdateExtractor calls
        // SessionFactExtractor.statesDurableFact directly, so a skipped turn must yield
        // nothing from either — verified here against a mock that would otherwise answer.
        let mock = MockLLMService()
        let question = "What foods should be avoided?"
        XCTAssertFalse(gates(question))

        let facts = await SessionFactExtractor().extract(from: question, using: mock)
        XCTAssertTrue(facts.isEmpty, "a question states no durable fact")

        let proposals = await ProfileUpdateExtractor().extract(
            from: question,
            currentProfile: Self.blankProfile,
            using: mock
        )
        XCTAssertTrue(proposals.isEmpty, "the profile pass must skip the same turns")
    }
}
