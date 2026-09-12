import XCTest
@testable import MobiCureVN

/// The two post-answer passes (`SessionFactExtractor`, `ProfileUpdateExtractor`) each run a full
/// on-device generation. They do not delay the current answer — both run after `.final` is
/// yielded — but they hold the single `ModelContainer`, so an ungated pass makes the user's NEXT
/// message queue behind a generation that was never going to return anything.
///
/// These tests pin the shared predicate both passes use, and in particular that it matches whole
/// words: the first version matched substrings and fired inside "urostomy", "syndrome" and every
/// question that merely named a topic.
@MainActor
final class AuxPassGatingTests: XCTestCase {

    private func gates(_ text: String) -> Bool {
        SessionFactExtractor.statesDurableFact(text)
    }

    /// A profile with nothing on file — the state where the extractor has the most to propose,
    /// so gating it here is the strongest form of the assertion.
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
        XCTAssertFalse(gates("What does a normal recovery look like?"))
        XCTAssertFalse(gates("How often should the pouch be changed?"))
        XCTAssertFalse(gates("When does recovery usually finish?"))
    }

    func testAQuestionThatOnlyNamesATopicSkips() {
        XCTAssertFalse(gates("What is a stoma?"))
        XCTAssertFalse(gates("How long does bowel surgery take?"))
        XCTAssertFalse(gates("Hậu môn nhân tạo là gì?"))
    }

    func testCuesNoLongerFireInsideOtherWords() {
        // Regressions from golden-set questions the substring gate ran both passes for.
        XCTAssertFalse(gates("What should clinicians consider before giving antibiotics for urinary infection in urostomy patients?"), "\"my\" inside \"urostomy\"")
        XCTAssertFalse(gates("What is low anterior resection syndrome (LARS) and what causes it?"), "\"me\" inside \"syndrome\"")
        XCTAssertFalse(gates("How much time off work is typical?"), "\"me\" inside \"time\"")
    }

    func testAPlainVietnameseQuestionStatesNoDurableFact() {
        XCTAssertFalse(gates("Nên ăn gì để mau hồi phục?"))
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
        XCTAssertTrue(gates("I\u{2019}m on FOLFOX now"), "a typographic apostrophe is still \"i'm\"")
        XCTAssertTrue(gates("A 62-year-old with a new stoma"), "\"year-old\" reads as \"year old\"")
    }

    func testVietnameseSelfDisclosureIsCaught() {
        XCTAssertTrue(gates("Tôi 62 tuổi"))
        XCTAssertTrue(gates("Tôi bị dị ứng với penicillin"))
        XCTAssertTrue(gates("Mình vừa mổ tuần trước"))
        XCTAssertTrue(gates("toi bi dau bung"), "typed without diacritics")
        XCTAssertTrue(gates("To\u{0302}i bi\u{0323} đau"), "decomposed input from some keyboards")
    }

    func testSelfReportWithoutAPronounIsCaught() {
        XCTAssertTrue(gates("Diagnosed with stage 2 rectal cancer last month"))
        XCTAssertTrue(gates("Taking metformin twice daily"))
        XCTAssertTrue(gates("Allergic to penicillin"))
        XCTAssertTrue(gates("Bị đau bụng từ hôm qua"), "Vietnamese routinely drops the subject")
    }

    // MARK: - The gate is shared, not duplicated

    func testBothPassesAgreeOnWhatCountsAsADisclosure() async {
        // Two gates drifting apart would be worse than one: a turn could update the session store
        // but never the profile, or the reverse. ProfileUpdateExtractor calls
        // SessionFactExtractor.statesDurableFact directly, so a skipped turn must yield nothing
        // from either — verified against a backend that records whether it was asked at all.
        let recorder = RecordingLLMService()
        let question = "What foods should be avoided?"
        XCTAssertFalse(gates(question))

        let facts = await SessionFactExtractor().extract(from: question, using: recorder)
        XCTAssertTrue(facts.isEmpty)
        let proposals = await ProfileUpdateExtractor().extract(
            from: question, currentProfile: Self.blankProfile, using: recorder
        )
        XCTAssertTrue(proposals.isEmpty)
        XCTAssertTrue(recorder.requests.isEmpty, "a gated turn must not reach the model in either pass")
    }

    func testTheProfilePassAsksForTheExtractionPreset() async {
        // It used to send no options and inherit the answer preset: the whole answer budget at
        // answering temperature, for a short JSON array.
        let recorder = RecordingLLMService()
        _ = await ProfileUpdateExtractor().extract(
            from: "I am allergic to penicillin", currentProfile: Self.blankProfile, using: recorder
        )
        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(recorder.requests.first?.options, .extraction)
    }
}

/// Records every request and answers with an empty JSON array.
private nonisolated final class RecordingLLMService: LLMServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [LLMRequest] = []

    var requests: [LLMRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    nonisolated func stream(request: LLMRequest) -> AsyncStream<String> {
        lock.lock()
        recorded.append(request)
        lock.unlock()
        return AsyncStream { continuation in
            continuation.yield("[]")
            continuation.finish()
        }
    }
}
