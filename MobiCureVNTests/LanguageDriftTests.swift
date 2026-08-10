import XCTest
@testable import MobiCureVN

/// Adversarial tests for LanguageValidationService — Suite 7 of the red-team script.
///
/// Focused on the two deterministic gates added when generation moved into the user's language:
/// `checkGeneratedLanguage` (drift detection on the model's output) and the foreign-script
/// short-circuit in `detect` (refusal on the input side). Both are pure functions, so every case
/// here runs without touching the LLM.
@MainActor
final class LanguageDriftTests: XCTestCase {

    private var sut: LanguageValidationService!
    private var llmService: MockLLMService!

    override func setUp() {
        super.setUp()
        sut = LanguageValidationService()
        llmService = MockLLMService()
    }

    override func tearDown() {
        sut = nil
        llmService = nil
        super.tearDown()
    }

    // MARK: - Foreign-script short-circuit refuses legitimate questions

    /// Traditional-medicine names are routinely written in Han characters by Vietnamese
    /// patients. `detect` short-circuits on any Han/Kana/Hangul/Thai character, so an otherwise
    /// ordinary Vietnamese question is refused with "only supports Vietnamese and English".
    func testVietnameseQuestionContainingAHanHerbNameIsAnswered() async {
        XCTExpectFailure("""
        Gap: containsForeignScript is a whole-text veto with no density notion. One Han token in \
        an otherwise Vietnamese sentence refuses the turn. A density/ratio test (as already used \
        for Vietnamese) would let a single foreign token through.
        """)
        let result = await sut.detect("Tôi uống 三七 được không sau khi mổ?", using: llmService)
        XCTAssertEqual(result, .vietnamese)
    }

    /// Regression guard: a genuinely foreign-language turn must still be refused.
    func testFullyChineseInputIsStillUnsupported() async {
        let result = await sut.detect("这是中文文本需要翻译成英文", using: llmService)
        XCTAssertEqual(result, .unsupported(detected: "foreign-script"))
    }

    // MARK: - Output drift detection

    /// Full drift into English is the one case with a clean repair path (Apple Translation).
    func testFullEnglishDriftIsFlaggedAsWrongLanguage() {
        let english = "You should clean the skin around the stoma daily with warm water and pat it dry."
        XCTAssertEqual(sut.checkGeneratedLanguage(english, expected: .vietnamese), .wrongLanguage)
    }

    /// Partial drift is detected but deliberately shipped as-is — there is no English original
    /// to re-translate from. This test pins that decision so it is a choice, not an accident.
    func testCodeSwitchedOutputIsFlaggedButNotRepairable() {
        let leaked = "Bạn nên thay túi hậu môn nhân tạo mỗi ngày. If the skin around it is red, please consult your nurse."
        XCTAssertEqual(sut.checkGeneratedLanguage(leaked, expected: .vietnamese), .codeSwitched)
    }

    func testForeignScriptInOutputIsFlagged() {
        let leaked = "Tránh thức ăn 油腻 và khó tiêu hóa sau phẫu thuật."
        XCTAssertEqual(sut.checkGeneratedLanguage(leaked, expected: .vietnamese), .foreignScript)
    }

    /// The system prompt explicitly instructs the model to put an uncommon English medical term
    /// in brackets after the Vietnamese one. That instruction must not trip the leak detector.
    func testBracketedEnglishMedicalTermsDoNotCountAsDrift() {
        let correct = "Bạn nên vệ sinh vùng da quanh lỗ mở (peristomal skin) mỗi ngày bằng nước ấm và lau khô nhẹ nhàng."
        XCTAssertEqual(sut.checkGeneratedLanguage(correct, expected: .vietnamese), .ok)
    }

    func testEnglishAnswerMentioningVietnameseFoodsIsNotFlagged() {
        let correct = "After surgery you can eat soft foods such as phở broth or cháo until your appetite returns."
        XCTAssertEqual(sut.checkGeneratedLanguage(correct, expected: .english), .ok)
    }

    func testShortVietnameseConfirmationIsNotFlagged() {
        XCTAssertEqual(sut.checkGeneratedLanguage("Vâng, đúng vậy.", expected: .vietnamese), .ok)
    }

    func testEmptyOutputIsTreatedAsOk() {
        XCTAssertEqual(sut.checkGeneratedLanguage("   \n ", expected: .vietnamese), .ok)
    }

    /// A Vietnamese answer written without tone marks scores below the density threshold and is
    /// classified `.wrongLanguage` — which sends already-Vietnamese text through the en→vi
    /// Apple Translation repair path in `ChatService`, garbling a correct answer.
    func testAccentlessVietnameseOutputIsNotMisreadAsEnglish() {
        let accentless = "Toi khuyen ban nen an chao va uong nhieu nuoc trong tuan dau tien"
        XCTExpectFailure("""
        Gap: vietnameseDensity here is ~0.2 (only `toi` and `va` are accent-less function words), \
        below the 0.25 threshold → .wrongLanguage → ChatService runs translateToVietnamese on \
        text that is already Vietnamese.
        """) {
            XCTAssertEqual(sut.checkGeneratedLanguage(accentless, expected: .vietnamese), .ok)
        }
    }

    // MARK: - Refinement gating

    func testAccentlessVietnameseIsRefined() {
        XCTAssertTrue(sut.needsRefinement("toi bi dau bung sau khi an com"))
    }

    func testCodeSwitchedInputIsRefined() {
        XCTAssertTrue(sut.needsRefinement("Tôi bị leakage quanh stoma, is that normal?"))
    }

    func testCleanVietnameseSkipsRefinement() {
        XCTAssertFalse(sut.needsRefinement("Tôi bị đau bụng sau khi phẫu thuật ruột"))
    }

    func testPlainEnglishSkipsRefinement() {
        XCTAssertFalse(sut.needsRefinement("What are the signs of a wound infection?"))
    }

    /// Ties Suite 7 back to Suite 2: a short accent-less emergency is BELOW the 3-word refine
    /// floor, so the accents are never restored — and `EmergencyDetector`'s diacritic-bearing
    /// patterns therefore never match it either. Two safe-looking guards leave a gap between them.
    func testShortAccentlessEmergencyIsNotRefinedAndSoIsNeverAccented() {
        XCTAssertFalse(sut.needsRefinement("dau nguc"),
                       "Documents the interaction: refine skips input under 3 words…")
        XCTAssertFalse(EmergencyDetector().detect(query: "dau nguc").isEmergency,
                       "…and the emergency table only matches accented `đau ngực`.")
    }
}
