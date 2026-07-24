import XCTest
@testable import MobiCureVN

/// Tests for WoundFindingsParser — the deterministic mapping from the VLM's structured
/// "KEY: value" findings text to WoundLogEntry fields, plus the review-flag heuristic.
final class WoundFindingsParserTests: XCTestCase {

    private let wellFormed = """
    STOMA_COLOR: pink
    STOMA_SIZE_CHANGE: unchanged
    SURROUNDING_SKIN: mild redness at lower edge
    OUTPUT_APPEARANCE: pasty, brown
    BAG_SEAL: intact
    SWELLING_OR_PROTRUSION: none
    OTHER: Not visible
    """

    func testParsesAllFieldsFromWellFormedOutput() {
        let parsed = WoundFindingsParser.parse(wellFormed)

        XCTAssertEqual(parsed.stomaColor, "pink")
        XCTAssertEqual(parsed.stomaSizeChange, "unchanged")
        XCTAssertEqual(parsed.surroundingSkin, "mild redness at lower edge")
        XCTAssertEqual(parsed.outputAppearance, "pasty, brown")
        XCTAssertEqual(parsed.bagSeal, "intact")
        XCTAssertEqual(parsed.swellingOrProtrusion, "none")
        XCTAssertEqual(parsed.otherObservations, "Not visible")
        XCTAssertFalse(parsed.flaggedForReview)
    }

    func testMissingKeyFallsBackToNotReported() {
        let partial = """
        STOMA_COLOR: red
        BAG_SEAL: intact
        """
        let parsed = WoundFindingsParser.parse(partial)

        XCTAssertEqual(parsed.stomaColor, "red")
        XCTAssertEqual(parsed.bagSeal, "intact")
        XCTAssertEqual(parsed.stomaSizeChange, WoundFindingsParser.notReported)
        XCTAssertEqual(parsed.surroundingSkin, WoundFindingsParser.notReported)
        XCTAssertEqual(parsed.otherObservations, WoundFindingsParser.notReported)
    }

    func testToleratesCasingWhitespaceAndListMarkers() {
        let messy = """
        - stoma_color :  Pink
        *  Bag_Seal:intact
          SWELLING_OR_PROTRUSION :   none
        """
        let parsed = WoundFindingsParser.parse(messy)

        XCTAssertEqual(parsed.stomaColor, "Pink")
        XCTAssertEqual(parsed.bagSeal, "intact")
        XCTAssertEqual(parsed.swellingOrProtrusion, "none")
    }

    func testUnknownLinesAndPreambleAreIgnored() {
        let noisy = """
        Here are the findings:
        STOMA_COLOR: pink
        NOTE: this is not a real key
        Some trailing prose.
        """
        let parsed = WoundFindingsParser.parse(noisy)

        XCTAssertEqual(parsed.stomaColor, "pink")
        XCTAssertEqual(parsed.otherObservations, WoundFindingsParser.notReported)
    }

    func testFirstOccurrenceOfRepeatedKeyWins() {
        let repeated = """
        STOMA_COLOR: pink
        STOMA_COLOR: red
        """
        XCTAssertEqual(WoundFindingsParser.parse(repeated).stomaColor, "pink")
    }

    func testEmptyValueIsTreatedAsNotReported() {
        let parsed = WoundFindingsParser.parse("STOMA_COLOR:\nBAG_SEAL: intact")
        XCTAssertEqual(parsed.stomaColor, WoundFindingsParser.notReported)
        XCTAssertEqual(parsed.bagSeal, "intact")
    }

    // MARK: - Review flag heuristic

    func testFlagsConcerningStomaColor() {
        XCTAssertTrue(WoundFindingsParser.shouldFlagForReview("STOMA_COLOR: dark purple"))
        XCTAssertTrue(WoundFindingsParser.shouldFlagForReview("STOMA_COLOR: dusky, almost black"))
    }

    func testFlagsInfectionSigns() {
        XCTAssertTrue(WoundFindingsParser.shouldFlagForReview("OUTPUT_APPEARANCE: purulent yellow discharge"))
        XCTAssertTrue(WoundFindingsParser.shouldFlagForReview("OTHER: foul odor and bleeding at the margin"))
    }

    func testFlagIsCaseInsensitive() {
        XCTAssertTrue(WoundFindingsParser.shouldFlagForReview("STOMA_COLOR: DARK"))
    }

    func testDoesNotFlagHealthyFindings() {
        XCTAssertFalse(WoundFindingsParser.shouldFlagForReview(wellFormed))
        XCTAssertFalse(WoundFindingsParser.shouldFlagForReview("STOMA_COLOR: pink\nOUTPUT_APPEARANCE: pasty, normal"))
    }

    func testParsedFlagMatchesHeuristic() {
        let concerning = """
        STOMA_COLOR: dark
        SWELLING_OR_PROTRUSION: significant swelling around the site
        """
        XCTAssertTrue(WoundFindingsParser.parse(concerning).flaggedForReview)
    }
}
