import XCTest
@testable import MobiCureVN

/// Vector search compares a query vector computed on the device with document vectors computed in
/// Python when the index was built. The two only meet if the Swift tokenizer and the CoreML model
/// reproduce `SentenceTransformer("BAAI/bge-small-en-v1.5")` exactly — a mismatch returns
/// confident nonsense, never an error. (The first converter mean-pooled a model that pools the
/// [CLS] token, and no test could have noticed.)
///
/// `MobiCureVNTests/Fixtures/QueryEmbedderParity.json` is written by
/// `Pipeline/tools/convert_embedder.py` from the model that built the index: token ids, attention
/// mask and reference embedding for texts chosen to exercise every tokenizer rule.
@MainActor
final class QueryEmbedderParityTests: XCTestCase {

    private struct Fixture: Decodable {
        struct Case: Decodable {
            let text: String
            let inputIds: [Int32]
            let attentionMask: [Int32]
            let embedding: [Float]
        }

        let model: String
        let pooling: String
        let maxSeqLen: Int
        let minCosineOnDevice: Double
        let cases: [Case]
    }

    private func loadFixture() throws -> Fixture {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "QueryEmbedderParity", withExtension: "json"),
            "QueryEmbedderParity.json missing from the test bundle — run Pipeline/tools/convert_embedder.py"
        )
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Fixture.self, from: Data(contentsOf: url))
    }

    func testTheQueryEmbedderShipsInTheAppBundle() {
        XCTAssertNotNil(Bundle.main.url(forResource: "vocab", withExtension: "txt"), "vocab.txt is not bundled")
        XCTAssertNotNil(
            QueryEmbedder(),
            "query_embedder is not bundled: retrieval silently degrades to FTS-only"
        )
    }

    func testTheSwiftTokenizerMatchesTheTokenizerThatBuiltTheIndex() throws {
        let fixture = try loadFixture()
        let vocabURL = try XCTUnwrap(Bundle.main.url(forResource: "vocab", withExtension: "txt"))
        let tokenizer = try XCTUnwrap(WordPieceTokenizer(vocabURL: vocabURL, maxSeqLen: fixture.maxSeqLen))

        for testCase in fixture.cases {
            let (ids, mask) = tokenizer.tokenize(testCase.text)
            XCTAssertEqual(ids, testCase.inputIds, "token ids differ for \(testCase.text.debugDescription)")
            XCTAssertEqual(mask, testCase.attentionMask, "attention mask differs for \(testCase.text.debugDescription)")
        }
    }

    func testTheOnDeviceModelMatchesTheModelThatBuiltTheIndex() throws {
        let fixture = try loadFixture()
        let embedder = try XCTUnwrap(QueryEmbedder(), "query_embedder is not bundled")

        for testCase in fixture.cases {
            let vector = try XCTUnwrap(embedder.embed(testCase.text), "no embedding for \(testCase.text.debugDescription)")
            XCTAssertEqual(vector.count, testCase.embedding.count)
            // Both sides are L2-normalised, so the dot product is the cosine. FP16 on the Neural
            // Engine costs a little precision; a pooling or tokenizer mismatch costs far more.
            let cosine = zip(vector, testCase.embedding).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
            XCTAssertGreaterThanOrEqual(
                cosine, fixture.minCosineOnDevice,
                "\(testCase.text.debugDescription): cosine \(cosine) against the index model"
            )
        }
    }
}
