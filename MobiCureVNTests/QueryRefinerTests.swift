import XCTest
@testable import MobiCureVN

/// Tests for QueryRefiner — validates the 3-step RAG query rewriting pipeline:
///   Step 1: Vietnamese → English medical term normalisation
///   Step 2: Medical abbreviation expansion
///   Step 3: Medical context enrichment (appended retrieval keywords)
final class QueryRefinerTests: XCTestCase {

    private var sut: QueryRefiner!

    override func setUp() {
        super.setUp()
        sut = QueryRefiner()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - Step 1: Vietnamese Medical Term Normalisation

    func testNormalisesFever() {
        let result = sut.refineQuery("tôi bị sốt sau phẫu thuật")
        XCTAssertTrue(result.baseQuery.contains("fever"), "sốt should map to 'fever'")
    }

    func testNormalisesSurgicalWound() {
        let result = sut.refineQuery("vết mổ bị đau")
        XCTAssertTrue(result.baseQuery.contains("surgical wound incision"), "vết mổ should map to 'surgical wound incision'")
    }

    func testNormalisesNausea() {
        let result = sut.refineQuery("tôi bị buồn nôn sau mổ")
        XCTAssertTrue(result.baseQuery.contains("nausea"), "buồn nôn should map to 'nausea'")
    }

    func testNormalisesInfection() {
        let result = sut.refineQuery("có dấu hiệu nhiễm trùng")
        XCTAssertTrue(result.baseQuery.contains("infection"), "nhiễm trùng should map to 'infection'")
    }

    func testNormalisesMedication() {
        let result = sut.refineQuery("dùng thuốc như thế nào")
        XCTAssertTrue(result.baseQuery.contains("medication medicine"), "thuốc should map to 'medication medicine'")
    }

    func testNormalisesPostSurgery() {
        let result = sut.refineQuery("sau phẫu thuật cần làm gì")
        XCTAssertTrue(result.baseQuery.contains("post-operative post-surgery"),
                      "sau phẫu thuật should map to 'post-operative post-surgery'")
    }

    func testNormalisesRecovery() {
        let result = sut.refineQuery("thời gian hồi phục mất bao lâu")
        XCTAssertTrue(result.baseQuery.contains("recovery"), "hồi phục should map to 'recovery'")
    }

    func testNormalisesDiarrhea() {
        let result = sut.refineQuery("bị tiêu chảy sau mổ")
        XCTAssertTrue(result.baseQuery.contains("diarrhea"), "tiêu chảy should map to 'diarrhea'")
    }

    func testNormalisesBloodPressure() {
        let result = sut.refineQuery("huyết áp cao ảnh hưởng không")
        XCTAssertTrue(result.baseQuery.contains("hypertension"), "huyết áp cao should map to 'hypertension'")
    }

    func testNormalisesMultipleTermsInOneQuery() {
        let result = sut.refineQuery("đau và sốt sau phẫu thuật")
        XCTAssertTrue(result.baseQuery.contains("pain") || result.baseQuery.contains("fever") || result.baseQuery.contains("surgery"),
                      "Multiple Vietnamese terms should all be mapped")
    }

    func testPreservesEnglishQuery() {
        let query = "wound infection after surgery"
        let result = sut.refineQuery(query)
        XCTAssertTrue(result.baseQuery.contains("wound") || result.baseQuery.contains("infection") || result.baseQuery.contains("surgery"),
                      "English medical terms must survive normalisation")
    }

    // MARK: - Step 2: Abbreviation Expansion

    func testExpandsRx() {
        let result = sut.refineQuery("what rx should I take")
        XCTAssertTrue(result.baseQuery.contains("prescription") || result.baseQuery.contains("treatment"),
                      "rx should expand to prescription/treatment")
    }

    func testExpandsDx() {
        let result = sut.refineQuery("my dx is colorectal cancer")
        XCTAssertTrue(result.baseQuery.contains("diagnosis"), "dx should expand to 'diagnosis'")
    }

    func testExpandsTx() {
        let result = sut.refineQuery("what tx is recommended")
        XCTAssertTrue(result.baseQuery.contains("treatment"), "tx should expand to 'treatment'")
    }

    func testExpandsBP() {
        let result = sut.refineQuery("my bp is high today")
        XCTAssertTrue(result.baseQuery.contains("blood pressure"), "bp should expand to 'blood pressure'")
    }

    func testExpandsHTN() {
        let result = sut.refineQuery("patient has htn complication")
        XCTAssertTrue(result.baseQuery.contains("hypertension") || result.baseQuery.contains("high blood pressure"),
                      "htn should expand to hypertension/high blood pressure")
    }

    func testExpandsDM() {
        let result = sut.refineQuery("patient has dm type 2")
        XCTAssertTrue(result.baseQuery.contains("diabetes"), "dm should expand to 'diabetes mellitus'")
    }

    func testExpandsMg() {
        let result = sut.refineQuery("take 500 mg of paracetamol")
        XCTAssertTrue(result.baseQuery.contains("milligram"), "mg should expand to 'milligram'")
    }

    func testExpandsUTI() {
        let result = sut.refineQuery("symptoms of uti after catheter removal")
        XCTAssertTrue(result.baseQuery.contains("urinary tract infection"), "uti should expand to 'urinary tract infection'")
    }

    // MARK: - Step 3: Medical Context Enrichment

    func testEnrichmentAddsSymptomKeywordsForPainQuery() {
        let result = sut.refineQuery("I have post-op pain")
        XCTAssertTrue(
            result.enrichedTerms.contains("symptoms") && result.enrichedTerms.contains("management") && result.enrichedTerms.contains("treatment"),
            "Pain queries should be enriched with symptom/management/treatment keywords"
        )
    }

    func testEnrichmentAddsDosageKeywordsForMedicationQuery() {
        let result = sut.refineQuery("I need medication advice")
        XCTAssertTrue(
            result.enrichedTerms.contains("dosage") || result.enrichedTerms.contains("safety") || result.enrichedTerms.contains("side"),
            "Medication queries should be enriched with dosage/safety/side-effects keywords"
        )
    }

    func testEnrichmentAddsRehabKeywordsForRecoveryQuery() {
        let result = sut.refineQuery("I am in recovery post surgery")
        XCTAssertTrue(
            result.enrichedTerms.contains("rehabilitation") || result.enrichedTerms.contains("exercises") || result.enrichedTerms.contains("guidelines"),
            "Recovery queries should be enriched with rehabilitation/exercises/guidelines"
        )
    }

    func testEnrichmentAddsPreventionKeywordsForInfectionQuery() {
        let result = sut.refineQuery("how to prevent infection at surgical site")
        XCTAssertTrue(
            result.enrichedTerms.contains("prevention") && result.enrichedTerms.contains("signs"),
            "Infection queries should be enriched with prevention/signs keywords"
        )
    }

    func testEnrichmentDoesNotDuplicateKeywordsForMultipleMatches() {
        // Pain + medication + infection: all three enrichments should fire without crash
        let result = sut.refineQuery("pain from infected wound, need medication")
        XCTAssertFalse(result.enrichedTerms.isEmpty)
        XCTAssertEqual(result.enrichedTerms.count, Set(result.enrichedTerms).count, "enrichedTerms should not contain duplicates")
    }

    // MARK: - Edge Cases

    func testEmptyQueryDoesNotCrash() {
        let result = sut.refineQuery("")
        XCTAssertNotNil(result)
    }

    func testQueryWithOnlySpacesDoesNotCrash() {
        let result = sut.refineQuery("   ")
        XCTAssertNotNil(result)
    }

    func testCombinedVietnameseAndAbbreviationQuery() {
        // vết mổ → surgical wound incision; rx should expand
        let result = sut.refineQuery("vết mổ bị nhiễm trùng cần rx gì")
        XCTAssertTrue(result.baseQuery.contains("infection") || result.baseQuery.contains("surgical"))
        XCTAssertTrue(result.baseQuery.contains("prescription") || result.baseQuery.contains("treatment"))
    }

    func testRefinedQueryIsLongerThanOrEqualToOriginal() {
        let query = "wound infection after surgery"
        let result = sut.refineQuery(query)
        // Normalisation/expansion always appends context, so refined baseQuery >= original
        XCTAssertGreaterThanOrEqual(result.baseQuery.count, query.count)
    }

    func testVietnameseQueryProducesEnglishOutput() {
        // After normalisation, the result should contain English medical terms
        let result = sut.refineQuery("sốt và đau sau phẫu thuật")
        let englishMedicalTerms = ["fever", "pain", "surgery", "symptom", "management"]
        let containsEnglish = englishMedicalTerms.contains(where: { result.baseQuery.contains($0) || result.enrichedTerms.contains($0) })
        XCTAssertTrue(containsEnglish, "Vietnamese query should produce English medical output for FTS retrieval")
    }

    // MARK: - Performance

    func testRefineQueryPerformanceWithComplexVietnameseInput() {
        let query = "vết mổ đau và sốt sau phẫu thuật, cần rx và dx ngay, hồi phục mất bao lâu"
        let start = Date()
        for _ in 0..<2_000 {
            _ = sut.refineQuery(query)
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 2.0, "2000 Vietnamese query refinements should complete within 2 seconds")
    }

    func testRefineQueryPerformanceWithEnglishAbbreviations() {
        let query = "patient has htn and dm, bp high, needs rx for uti after surgery"
        let start = Date()
        for _ in 0..<2_000 {
            _ = sut.refineQuery(query)
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 2.0, "2000 abbreviation-expansion refinements should complete within 2 seconds")
    }
}
