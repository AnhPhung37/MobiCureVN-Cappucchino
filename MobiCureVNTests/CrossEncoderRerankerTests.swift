import XCTest
@testable import MobiCureVN

/// The reranker only helps if the phone scores pairs the way the model that was evaluated does.
/// A pair encoded differently (truncation side, token types) or a model converted wrongly does not
/// fail — it reorders retrieval by noise. `MobiCureVNTests/Fixtures/RerankerParity.json` is written
/// by `Pipeline/tools/convert_reranker.py` from the reference model.
@MainActor
final class CrossEncoderRerankerTests: XCTestCase {

    private struct Fixture: Decodable {
        struct Case: Decodable {
            let query: String
            let passage: String
            let inputIds: [Int32]
            let tokenTypeIds: [Int32]
            let attentionMask: [Int32]
            let score: Float
        }

        let model: String
        let maxSeqLen: Int
        let maxScoreDelta: Float
        let cases: [Case]
    }

    private func loadFixture() throws -> Fixture {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "RerankerParity", withExtension: "json"),
            "RerankerParity.json missing from the test bundle — run Pipeline/tools/convert_reranker.py"
        )
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Fixture.self, from: Data(contentsOf: url))
    }

    func testPairEncodingMatchesTheTokenizerThatScoredThePairs() throws {
        let fixture = try loadFixture()
        let vocabURL = try XCTUnwrap(Bundle.main.url(forResource: "vocab", withExtension: "txt"))
        let tokenizer = try XCTUnwrap(WordPieceTokenizer(vocabURL: vocabURL, maxSeqLen: fixture.maxSeqLen))

        for testCase in fixture.cases {
            let encoding = CrossEncoderReranker.encodePair(
                query: tokenizer.wordPieceIDs(for: testCase.query),
                passage: tokenizer.wordPieceIDs(for: testCase.passage),
                maxSeqLen: fixture.maxSeqLen
            )
            XCTAssertEqual(encoding.inputIDs, testCase.inputIds, "ids differ for \(testCase.query.prefix(40))")
            XCTAssertEqual(encoding.tokenTypeIDs, testCase.tokenTypeIds)
            XCTAssertEqual(encoding.attentionMask, testCase.attentionMask)
        }
    }

    func testOnDeviceScoresMatchTheReferenceModel() throws {
        let fixture = try loadFixture()
        let reranker = try XCTUnwrap(CrossEncoderReranker(), "reranker.mlpackage is not bundled")
        for testCase in fixture.cases {
            let score = try XCTUnwrap(reranker.score(query: testCase.query, passage: testCase.passage))
            XCTAssertEqual(score, testCase.score, accuracy: fixture.maxScoreDelta, "\(testCase.query.prefix(40))")
        }
        // The relevant passage must outrank the irrelevant one for the same question.
        XCTAssertGreaterThan(fixture.cases[0].score, fixture.cases[1].score)
    }

    /// Expected lengths were read off `AutoTokenizer(...)(query, passage, truncation="longest_first")`
    /// for the same token counts (room = 16 - 3 = 13).
    func testTruncationMatchesTheTokenizersLongestFirstRule() {
        func counts(_ queryCount: Int, _ passageCount: Int) -> (query: Int, passage: Int, passageTypes: Int) {
            let encoding = CrossEncoderReranker.encodePair(
                query: [Int32](repeating: 7, count: queryCount),
                passage: [Int32](repeating: 9, count: passageCount),
                maxSeqLen: 16
            )
            return (
                encoding.inputIDs.filter { $0 == 7 }.count,
                encoding.inputIDs.filter { $0 == 9 }.count,
                encoding.tokenTypeIDs.filter { $0 == 1 }.count
            )
        }

        XCTAssertTrue(counts(4, 100) == (4, 9, 10), "a side within half the room is kept whole")
        XCTAssertTrue(counts(100, 4) == (9, 4, 5))
        XCTAssertTrue(counts(20, 20) == (6, 7, 8), "on a tie the query gets the floor of half")
        XCTAssertTrue(counts(7, 30) == (6, 7, 8), "both over half: shorter side gets the floor")
        XCTAssertTrue(counts(30, 7) == (7, 6, 7))
        XCTAssertTrue(counts(5, 8) == (5, 8, 9), "a pair that fits is untouched")
    }

    func testTiesKeepRetrievalOrder() {
        XCTAssertEqual(CrossEncoderReranker.order(byScores: [0.1, 2.0, 0.1, 2.0]), [1, 3, 0, 2])
    }
}
