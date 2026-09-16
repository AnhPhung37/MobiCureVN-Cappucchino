import XCTest
@testable import MobiCureVN

/// Tests for MedicalGlossary — pins colorectal-recovery terms to clinical English before
/// Apple Translation, which otherwise picks everyday readings ("túi dịch" → "water bottle").
final class MedicalGlossaryTests: XCTestCase {

    private let sut = MedicalGlossary()

    func testTuiDichBecomesOstomyPouch() {
        XCTAssertEqual(sut.apply("Túi dịch của tôi đang bị tràn"), "ostomy pouch của tôi đang bị tràn")
    }

    func testLongestPhraseWins() {
        XCTAssertEqual(sut.apply("túi hậu môn nhân tạo bị rò"), "ostomy pouch bị rò")
        XCTAssertEqual(sut.apply("hậu môn nhân tạo sưng đỏ"), "stoma sưng đỏ")
        XCTAssertEqual(sut.apply("bị rò miệng nối không"), "bị anastomotic leak không")
    }

    func testRequiresWholePhrase() {
        // "túi dịchx" is not the phrase; a letter on either side must block the match.
        XCTAssertEqual(sut.apply("túi dịchx"), "túi dịchx")
    }

    func testDecomposedDiacriticsStillMatch() {
        let decomposed = "túi dịch bị tràn".decomposedStringWithCanonicalMapping
        XCTAssertEqual(sut.apply(decomposed), "ostomy pouch bị tràn")
    }

    func testUnrelatedTextUnchanged() {
        XCTAssertEqual(sut.apply("Tôi muốn uống một chai nước"), "Tôi muốn uống một chai nước")
        XCTAssertEqual(sut.apply("My pouch is leaking"), "My pouch is leaking")
    }

    func testMultipleTermsInOneSentence() {
        XCTAssertEqual(
            sut.apply("vết mổ và ống dẫn lưu bị chảy dịch"),
            "surgical incision và surgical drain bị chảy dịch"
        )
    }
}
