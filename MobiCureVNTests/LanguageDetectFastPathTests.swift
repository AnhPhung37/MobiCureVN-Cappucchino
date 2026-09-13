import XCTest
@testable import MobiCureVN

/// Tests for the English fast path in `LanguageValidationService.detect`.
///
/// Plain English used to escape both deterministic short-circuits — it carries no Vietnamese
/// diacritics and no Vietnamese function words, so both density gates read zero — and fell
/// through to a full LLM generation on the critical path, before the answer could start
/// prefilling. Short-circuit 3 removes that call.
///
/// The risk being guarded against is the opposite error: `NLLanguageRecognizer` misreads
/// accent-less Vietnamese ("toi bi dau bung") as Romanian or Polish, which is why this service
/// keeps an LLM classifier at all. These tests pin the asymmetry — the recogniser may only ever
/// *remove* an LLM call for text that is confidently English and has zero Vietnamese signal.
@MainActor
final class LanguageDetectFastPathTests: XCTestCase {

    private func detect(_ text: String) async -> (language: DetectedLanguage, usedLLM: Bool) {
        let llm = RecordingLLM()
        let language = await LanguageValidationService().detect(text, using: llm)
        return (language, llm.wasCalled)
    }

    // MARK: - English takes the fast path

    func testPlainEnglishSentenceSkipsTheLLM() async {
        let result = await detect("What are the signs that my surgical wound is infected?")
        XCTAssertEqual(result.language, .english)
        XCTAssertFalse(result.usedLLM, "plain English must not cost an LLM generation")
    }

    func testLongerEnglishClinicalQuestionSkipsTheLLM() async {
        let result = await detect("How often should I change my stoma pouch after surgery?")
        XCTAssertEqual(result.language, .english)
        XCTAssertFalse(result.usedLLM)
    }

    // MARK: - Vietnamese must never take the English fast path

    func testAccentlessVietnameseStillReachesTheLLM() async {
        // The exact string the service's own documentation names as the reason the LLM
        // classifier exists. NLLanguageRecognizer reports Romanian/Polish for it.
        let result = await detect("toi bi dau bung va khong an duoc gi")
        XCTAssertTrue(result.usedLLM, "accent-less Vietnamese must still go to the LLM")
        XCTAssertNotEqual(result.language, .english)
    }

    func testAccentedVietnameseSkipsTheLLMViaTheExistingShortCircuit() async {
        let result = await detect("Tôi bị đau bụng và không ăn được gì cả")
        XCTAssertEqual(result.language, .vietnamese)
        XCTAssertFalse(result.usedLLM, "short-circuit 2 already covered this")
    }

    func testEnglishSentenceMentioningAVietnamesePlaceNameDoesNotTakeTheFastPath() async {
        // One accented word gives non-zero Vietnamese signal, so the fast path must decline
        // and let the existing density logic decide.
        let result = await detect("The clinic in Hà Nội gave me antibiotics for the infection")
        XCTAssertTrue(result.usedLLM, "any Vietnamese signal must disqualify the English fast path")
    }

    // MARK: - The guards on the fast path

    func testAMedicalAcronymThatSpellsAVietnameseWordDoesNotCostTheLLM() async {
        // "GI" is also accent-less "gì". As an all-caps acronym in an English sentence it is not
        // Vietnamese signal, and this domain is full of it.
        let result = await detect("What does GI bleeding after bowel surgery look like?")
        XCTAssertEqual(result.language, .english)
        XCTAssertFalse(result.usedLLM)
    }

    func testCapsLockVietnameseIsNotMistakenForAcronyms() async {
        let result = await detect("TOI BI DAU BUNG VA KHONG AN DUOC GI")
        XCTAssertTrue(result.usedLLM, "with no lower-case letter anywhere, capitals are not evidence of an acronym")
    }

    func testAnAcronymDoesNotHideRealVietnameseAroundIt() async {
        let result = await detect("toi bi GI bleeding sau khi mo")
        XCTAssertTrue(result.usedLLM)
    }

    func testVeryShortEnglishDoesNotTakeTheFastPath() async {
        // Under the word floor the recogniser is close to guessing, and the turn is cheap to
        // classify properly.
        let result = await detect("thanks")
        XCTAssertTrue(result.usedLLM)
    }

    func testForeignScriptIsStillRejectedBeforeAnyLLMCall() async {
        let result = await detect("这是中文句子，不是越南语")
        XCTAssertFalse(result.usedLLM)
        XCTAssertEqual(result.language, .unsupported(detected: "foreign-script"))
    }

    func testEmptyInputIsUnchanged() async {
        let result = await detect("   ")
        XCTAssertEqual(result.language, .english)
        XCTAssertFalse(result.usedLLM)
    }
}

/// Answers "english" and records that it was asked, so a test can assert on the *cost* of a
/// verdict rather than only the verdict — a correct answer obtained via a full generation is
/// exactly the bug being fixed.
private nonisolated final class RecordingLLM: LLMServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var called = false

    var wasCalled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return called
    }

    nonisolated func stream(request: LLMRequest) -> AsyncStream<String> {
        lock.lock()
        called = true
        lock.unlock()
        return AsyncStream { continuation in
            continuation.yield("english")
            continuation.finish()
        }
    }
}
