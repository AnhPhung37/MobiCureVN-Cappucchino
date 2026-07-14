import XCTest
@testable import MobiCureVN

/// Tests for LanguageValidationService — verifies Vietnamese/English detection and routing.
/// A new build passes if:
///   - Empty/whitespace-only strings default to English
///   - Clear Vietnamese text (with diacritics) is detected as Vietnamese
///   - Clear English text is detected as English
///   - requiresTranslation is correct per language
@MainActor
final class LanguageValidationServiceTests: XCTestCase {

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

    // MARK: - Edge Cases

    func testEmptyStringDefaultsToEnglish() async {
        let result = await sut.detect("", using: llmService)
        XCTAssertEqual(result, .english)
    }

    func testWhitespaceOnlyDefaultsToEnglish() async {
        let result = await sut.detect("   \n\t  ", using: llmService)
        XCTAssertEqual(result, .english)
    }

    // MARK: - Vietnamese Detection

    func testVietnameseTextWithToneMarksDetected() async {
        let result = await sut.detect("Tôi bị đau bụng sau khi phẫu thuật ruột", using: llmService)
        XCTAssertEqual(result, .vietnamese)
    }

    func testVietnameseTextWithDiacriticsDetected() async {
        let result = await sut.detect("Vết thương của tôi đang chảy dịch màu vàng", using: llmService)
        XCTAssertEqual(result, .vietnamese)
    }

    func testVietnameseWithoutDiacriticsDetected() async {
        // Common real-world case: Vietnamese typed without accents on a mobile keyboard.
        let result = await sut.detect("toi bi dau bung", using: llmService)
        XCTAssertEqual(result, .vietnamese)
    }

    func testVietnameseResultRequiresTranslation() async {
        let result = await sut.detect("Tôi cần hỏi về thuốc uống sau mổ", using: llmService)
        XCTAssertTrue(result.requiresTranslation)
    }

    // MARK: - English Detection

    func testEnglishMedicalTextDetected() async {
        let result = await sut.detect("What are the signs of infection in a surgical wound?", using: llmService)
        XCTAssertEqual(result, .english)
    }

    func testEnglishPostOpQueryDetected() async {
        let result = await sut.detect("I have pain and nausea after my colorectal surgery yesterday", using: llmService)
        XCTAssertEqual(result, .english)
    }

    func testEnglishResultDoesNotRequireTranslation() async {
        let result = await sut.detect("My recovery is going well but I have mild discomfort", using: llmService)
        XCTAssertFalse(result.requiresTranslation)
    }

    // MARK: - requiresTranslation Logic

    func testVietnameseAlwaysRequiresTranslation() {
        XCTAssertTrue(DetectedLanguage.vietnamese.requiresTranslation)
    }

    func testMixedAlwaysRequiresTranslation() {
        XCTAssertTrue(DetectedLanguage.mixed.requiresTranslation)
    }

    func testEnglishNeverRequiresTranslation() {
        XCTAssertFalse(DetectedLanguage.english.requiresTranslation)
    }

    func testUnsupportedLanguageDoesNotRequireTranslation() {
        XCTAssertFalse(DetectedLanguage.unsupported(detected: "fr").requiresTranslation)
    }

    // MARK: - DetectedLanguage Equality

    func testVietnameseEquality() {
        XCTAssertEqual(DetectedLanguage.vietnamese, DetectedLanguage.vietnamese)
    }

    func testEnglishEquality() {
        XCTAssertEqual(DetectedLanguage.english, DetectedLanguage.english)
    }

    func testMixedEquality() {
        XCTAssertEqual(DetectedLanguage.mixed, DetectedLanguage.mixed)
    }

    func testUnsupportedEqualityMatchesCode() {
        XCTAssertEqual(DetectedLanguage.unsupported(detected: "fr"), DetectedLanguage.unsupported(detected: "fr"))
        XCTAssertNotEqual(DetectedLanguage.unsupported(detected: "fr"), DetectedLanguage.unsupported(detected: "de"))
    }

    func testVietnameseNotEqualToEnglish() {
        XCTAssertNotEqual(DetectedLanguage.vietnamese, DetectedLanguage.english)
    }

    // MARK: - Foreign Script Detection

    func testDetectsChineseScriptLeak() {
        XCTAssertTrue(sut.containsForeignScript("Tránh thức ăn 油腻 và khó tiêu hóa"))
    }

    func testDetectsJapaneseScript() {
        XCTAssertTrue(sut.containsForeignScript("こんにちは"))
    }

    func testDetectsKoreanScript() {
        XCTAssertTrue(sut.containsForeignScript("안녕하세요"))
    }

    func testDetectsThaiScript() {
        XCTAssertTrue(sut.containsForeignScript("สวัสดี"))
    }

    func testPureVietnameseHasNoForeignScript() {
        XCTAssertFalse(sut.containsForeignScript("Sau phẫu thuật, bạn nên ăn thức ăn dễ tiêu hóa."))
    }

    func testPureEnglishHasNoForeignScript() {
        XCTAssertFalse(sut.containsForeignScript("You should eat easily digestible food after surgery."))
    }

    // MARK: - Unsupported Error Message

    func testUnsupportedErrorMessageIsNotEmpty() {
        XCTAssertFalse(LanguageValidationService.unsupportedErrorMessage.isEmpty)
    }

    func testUnsupportedErrorMessageIsBilingual() {
        let message = LanguageValidationService.unsupportedErrorMessage
        // Should contain both Vietnamese and English guidance
        XCTAssertTrue(message.contains("Xin lỗi"))
        XCTAssertTrue(message.contains("Sorry"))
    }

    // MARK: - Refine

    func testRefineReturnsNonEmptyResultForNonEmptyInput() async {
        let result = await sut.refine("toi bi dau bung", using: llmService)
        XCTAssertFalse(result.isEmpty)
    }

    func testRefineReturnsOriginalForEmptyInput() async {
        let result = await sut.refine("", using: llmService)
        XCTAssertEqual(result, "")
    }

    // MARK: - Matches

    func testMatchesReturnsTrueForEmptyText() async {
        let result = await sut.matches("", expected: .vietnamese, using: llmService)
        XCTAssertTrue(result)
    }

    func testMatchesReturnsFalseForForeignScriptLeak() async {
        let result = await sut.matches("Tránh thức ăn 油腻 và khó tiêu hóa", expected: .vietnamese, using: llmService)
        XCTAssertFalse(result)
    }

    func testMatchesReturnsTrueForCorrectVietnamese() async {
        let result = await sut.matches("Sau phẫu thuật, bạn nên ăn thức ăn dễ tiêu hóa.", expected: .vietnamese, using: llmService)
        XCTAssertTrue(result)
    }

    func testMatchesReturnsTrueForCorrectEnglish() async {
        let result = await sut.matches("You should eat easily digestible food after surgery.", expected: .english, using: llmService)
        XCTAssertTrue(result)
    }

    // MARK: - Translate Fallback

    func testTranslateAsFallbackReturnsNonEmptyResult() async {
        let result = await sut.translateAsFallback("You should rest after surgery.", to: .vietnamese, using: llmService)
        XCTAssertFalse(result.isEmpty)
    }

    func testTranslateAsFallbackReturnsOriginalForEmptyInput() async {
        let result = await sut.translateAsFallback("", to: .vietnamese, using: llmService)
        XCTAssertEqual(result, "")
    }
}
