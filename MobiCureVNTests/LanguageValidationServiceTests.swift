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

    // MARK: - Density-Based Detection (issue #2 regression table)

    /// Table covering the density/detect contract. The key regression case is an English
    /// sentence carrying a single Vietnamese place name: it must stay .english and NOT be
    /// promoted to .mixed (which used to trigger on any single diacritic).
    func testDetectionTable() async {
        struct Case {
            let name: String
            let text: String
            let expected: DetectedLanguage
        }

        let cases: [Case] = [
            Case(name: "pure English",
                 text: "What are the signs of infection in a surgical wound?",
                 expected: .english),
            Case(name: "English + one Vietnamese place name (regression)",
                 text: "I had my surgery at a hospital in Đà Nẵng last week and feel fine.",
                 expected: .english),
            Case(name: "pure Vietnamese",
                 text: "Tôi bị đau bụng dữ dội sau khi phẫu thuật ruột hôm qua.",
                 expected: .vietnamese),
            Case(name: "accent-less Vietnamese",
                 text: "toi bi dau bung sau khi mo",
                 expected: .vietnamese),
            Case(name: "CJK leakage",
                 text: "这是中文文本需要翻译成英文",
                 expected: .unsupported(detected: "foreign-script")),
        ]

        for c in cases {
            let result = await sut.detect(c.text, using: llmService)
            XCTAssertEqual(result, c.expected, "Case failed: \(c.name) — got \(result)")
        }
    }

    func testEnglishWithVietnamesePlaceNameStaysEnglish() async {
        // Explicit spotlight on the misrouting bug: one accented word must not flip to .mixed.
        let result = await sut.detect(
            "The clinic in Hà Nội gave me antibiotics for my wound infection.",
            using: llmService
        )
        XCTAssertEqual(result, .english)
        XCTAssertFalse(result.requiresTranslation)
    }

    func testLLMVietnameseVerdictVetoedForZeroSignalEnglish() async {
        // Reproduces the field bug: the small on-device classifier answered "vietnamese"
        // for a pure-English sentence. With zero Vietnamese density, detect must veto that
        // verdict and return .english rather than mis-route the turn through translation.
        let stub = StubLLMService(reply: "vietnamese")
        let result = await sut.detect(
            "Does my period affect the recovery of the wound?",
            using: stub
        )
        XCTAssertEqual(result, .english)
        XCTAssertFalse(result.requiresTranslation)
    }

    func testLLMVietnameseVerdictTrustedForAccentlessVietnamese() async {
        // The veto must NOT fire for genuine accent-less Vietnamese: it carries function-word
        // signal, so a "vietnamese" verdict is trusted.
        let stub = StubLLMService(reply: "vietnamese")
        let result = await sut.detect("toi bi dau bung khong", using: stub)
        XCTAssertEqual(result, .vietnamese)
    }

    func testDensityLowForEnglishWithOneAccentedPlaceName() {
        // A two-word Vietnamese place name in a short English sentence must stay below the
        // dominance threshold (0.25), so it is not treated as Vietnamese-dominant.
        let density = sut.vietnameseDensity("I visited Đà Nẵng for a checkup this morning today")
        XCTAssertLessThan(density, 0.25)
    }

    func testDensityHighForPureVietnamese() {
        let density = sut.vietnameseDensity("Tôi bị đau bụng và buồn nôn sau phẫu thuật")
        XCTAssertGreaterThanOrEqual(density, 0.35)
    }

    func testDensityCatchesAccentlessVietnameseFunctionWords() {
        // No diacritics at all, but the function words carry the signal.
        let density = sut.vietnameseDensity("toi bi dau bung khong")
        XCTAssertGreaterThan(density, 0.0)
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

    // MARK: - LLM Translate

    func testTranslateReturnsNonEmptyResult() async {
        let result = await sut.translate("You should rest after surgery.", to: .vietnamese, using: llmService)
        XCTAssertFalse(result.isEmpty)
    }

    func testTranslateReturnsOriginalForEmptyInput() async {
        let result = await sut.translate("", to: .vietnamese, using: llmService)
        XCTAssertEqual(result, "")
    }
}

/// Minimal LLM stub that always yields a fixed reply, letting a test force a specific
/// classifier verdict (e.g. a spurious "vietnamese") regardless of the input text.
private nonisolated final class StubLLMService: LLMServiceProtocol {
    private let reply: String
    init(reply: String) { self.reply = reply }

    nonisolated func stream(request: LLMRequest) -> AsyncStream<String> {
        let reply = self.reply
        return AsyncStream { continuation in
            continuation.yield(reply)
            continuation.finish()
        }
    }
}
