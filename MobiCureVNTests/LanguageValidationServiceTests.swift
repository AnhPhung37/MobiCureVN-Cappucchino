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

    override func setUp() {
        super.setUp()
        sut = LanguageValidationService()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - Edge Cases

    func testEmptyStringDefaultsToEnglish() {
        XCTAssertEqual(sut.detect(""), .english)
    }

    func testWhitespaceOnlyDefaultsToEnglish() {
        XCTAssertEqual(sut.detect("   \n\t  "), .english)
    }

    // MARK: - Vietnamese Detection

    func testVietnameseTextWithToneMarksDetected() {
        let result = sut.detect("Tôi bị đau bụng sau khi phẫu thuật ruột")
        XCTAssertEqual(result, .vietnamese)
    }

    func testVietnameseTextWithDiacriticsDetected() {
        let result = sut.detect("Vết thương của tôi đang chảy dịch màu vàng")
        XCTAssertEqual(result, .vietnamese)
    }

    func testVietnameseResultRequiresTranslation() {
        let result = sut.detect("Tôi cần hỏi về thuốc uống sau mổ")
        XCTAssertTrue(result.requiresTranslation)
    }

    // MARK: - English Detection

    func testEnglishMedicalTextDetected() {
        let result = sut.detect("What are the signs of infection in a surgical wound?")
        XCTAssertEqual(result, .english)
    }

    func testEnglishPostOpQueryDetected() {
        let result = sut.detect("I have pain and nausea after my colorectal surgery yesterday")
        XCTAssertEqual(result, .english)
    }

    func testEnglishResultDoesNotRequireTranslation() {
        let result = sut.detect("My recovery is going well but I have mild discomfort")
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
}
