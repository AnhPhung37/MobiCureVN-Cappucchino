import XCTest
@testable import MobiCureVN

/// Adversarial tests for InputGuardRail's PII rules — Suite 3 of the red-team script.
///
/// Two things make this worth testing separately from the allow/block decision: the masked
/// query is what reaches RAG retrieval, the LLM prompt, AND the session fact extractor
/// (`MedicalChatOrchestrator` uses `inputResult.sanitizedQuery` throughout), so over-masking
/// silently degrades answer quality; and the Vietnamese address rule is a plain word-alternation
/// that collides with core domain vocabulary.
///
/// The word `đường` means **street** — and also **sugar**, and appears in `đường ruột`
/// (intestinal tract) and `đường tiêu hóa` (digestive tract). For a colorectal app, that is
/// the vocabulary of the domain, not an address.
@MainActor
final class PIIMaskingCollateralTests: XCTestCase {

    private var sut: InputGuardRail!

    override func setUp() {
        super.setUp()
        sut = InputGuardRail()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - Over-masking: `đường` is domain vocabulary, not an address

    func testIntestinalTractQuestionIsNotMaskedAsAnAddress() {
        XCTExpectFailure("""
        Gap: the ADDRESS rule `(đường|phố|phường|quận|huyện|tỉnh)\\s+[^,\\.]+` treats `đường ruột` \
        (intestinal tract) as a street name and masks from there to the end of the clause — so \
        RAG retrieves on a query with its clinical subject removed.
        """) {
            let result = sut.validate(query: "Tôi bị viêm đường ruột thì nên ăn gì?")
            let sanitized = result.sanitizedQuery ?? ""
            XCTAssertTrue(sanitized.contains("đường ruột"),
                          "Clinical term should survive masking, got: \(sanitized)")
        }
    }

    func testBloodSugarQuestionIsNotMaskedAsAnAddress() {
        XCTExpectFailure("Gap: `đường huyết` (blood sugar) matches the same street-name rule.") {
            let result = sut.validate(query: "Chỉ số đường huyết của tôi cao thì nên kiêng gì?")
            let sanitized = result.sanitizedQuery ?? ""
            XCTAssertTrue(sanitized.contains("đường huyết"),
                          "Clinical term should survive masking, got: \(sanitized)")
        }
    }

    /// The rule has no upper bound — `[^,\.]+` runs to the next comma or full stop, so a
    /// question mark does not terminate it and the rest of the sentence is swallowed.
    func testAddressRuleDoesNotSwallowTheRestOfTheSentence() {
        let result = sut.validate(query: "Tôi bị viêm đường tiêu hóa và buồn nôn nhiều")
        let sanitized = result.sanitizedQuery ?? ""
        XCTExpectFailure("Gap: unbounded `[^,\\.]+` masks everything up to the next comma or period.") {
            XCTAssertTrue(sanitized.contains("buồn nôn"),
                          "Symptom after the false-positive match should survive, got: \(sanitized)")
        }
    }

    // MARK: - Under-masking: real addresses get through

    /// The PII regexes are compiled with `options: []` — no `.caseInsensitive`. Vietnamese
    /// addresses are conventionally capitalised, which is exactly the form that does not match.
    func testCapitalisedVietnameseAddressIsMasked() {
        XCTExpectFailure("""
        Gap: InputGuardRail compiles piiPatterns without .caseInsensitive, so `Đường`/`Quận` \
        (the normal written form of an address) never match — while lower-case `đường` in \
        clinical prose does. The rule is inverted with respect to real usage.
        """) {
            let result = sut.validate(query: "Tôi sống ở Đường Lê Lợi Quận 1 thì khám ở đâu gần nhất?")
            let sanitized = result.sanitizedQuery ?? ""
            XCTAssertFalse(sanitized.contains("Lê Lợi"), "Address should be masked, got: \(sanitized)")
        }
    }

    /// The bigger structural issue: `InputGuardRail` runs on the ENGLISH translation, so the
    /// Vietnamese address rule never sees Vietnamese text in production at all.
    func testTranslatedVietnameseAddressIsMasked() {
        XCTExpectFailure("""
        Gap: by the time validate() runs, "đường Lê Lợi, quận 1" has become "Le Loi street, \
        District 1". No English address rule exists, so the address reaches the LLM prompt \
        unmasked. Same class of bypass as InputGuardRailBypassTests.
        """) {
            let result = sut.validate(query: "I live on Le Loi street in District 1, which hospital is nearest?")
            let sanitized = result.sanitizedQuery ?? ""
            XCTAssertFalse(sanitized.contains("Le Loi"), "Address should be masked, got: \(sanitized)")
        }
    }

    // MARK: - Regression guards: masking that must keep working

    func testDosageNumbersAreNotMasked() {
        let result = sut.validate(query: "I take 500mg of paracetamol 3 times a day, is that too much?")
        let sanitized = result.sanitizedQuery ?? ""
        XCTAssertTrue(sanitized.contains("500mg"), "Dosage must survive PII masking, got: \(sanitized)")
        XCTAssertTrue(sanitized.contains("3 times"), "Frequency must survive, got: \(sanitized)")
    }

    func testEmailIsMaskedButTheClinicalQuestionSurvives() {
        let result = sut.validate(query: "Email me at patient@hospital.vn — is my wound infected?")
        let sanitized = result.sanitizedQuery ?? ""
        XCTAssertFalse(sanitized.contains("patient@hospital.vn"))
        XCTAssertTrue(sanitized.contains("wound infected"), "Question must survive, got: \(sanitized)")
    }

    func testTwelveDigitNumberIsMaskedRegardlessOfContext() {
        // Correct outcome (the number is masked), but note the violation is labelled CCCD even
        // when the number is a hospital record ID — the rule is a bare `\d{12}` with no context.
        let result = sut.validate(query: "My medical record number is 202401150034 and my wound hurts")
        let sanitized = result.sanitizedQuery ?? ""
        XCTAssertFalse(sanitized.contains("202401150034"))
        XCTAssertTrue(result.violations.contains { $0.contains("CCCD") },
                      "Documents the mislabel: any 12-digit run is reported as a national ID")
    }

    /// Structural: the masked text — not the original — is what flows onward to RAG, the LLM
    /// prompt, and `SessionFactExtractor`. This is why over-masking is a correctness problem
    /// and not just a privacy nicety.
    func testSanitizedQueryIsTheTextThatFlowsDownstream() {
        let original = "Gọi tôi số 0901234567, vết mổ của tôi bị sưng"
        let result = sut.validate(query: original)
        XCTAssertEqual(result.originalQuery, original, "Original must be preserved for logging")
        XCTAssertNotEqual(result.sanitizedQuery, original, "Downstream stages consume the masked form")
        XCTAssertTrue(result.sanitizedQuery?.contains("[MASKED]") ?? false)
    }
}
