import XCTest
@testable import MobiCureVN

/// The two Gemma-family entries added for the medical and small-footprint candidates. Their
/// values come from measurements that cannot run on the device, so the test pins them: a change
/// here should come with a re-measurement (Docs/BE/Model-Catalog-Candidates.md).
@MainActor
final class ModelCatalogCandidatesTests: XCTestCase {

    func testBothCandidatesAreVisionModelsWithTheGemmaRatio() {
        for model in [ModelCatalog.medgemma1_5_4B, .gemma4_E2B] {
            XCTAssertTrue(model.supportsVision, "\(model) ships a vision tower and must load through VLMModelFactory")
            // Pipeline/tools/measure_token_ratio.py on the 1876-chunk corpus: EN 1.693, VI 1.204.
            XCTAssertEqual(model.wordsToTokensRatio, 1.70)
        }
    }

    func testRepoIDsPointAtTheMLXConversions() {
        XCTAssertEqual(ModelCatalog.medgemma1_5_4B.repoID, "mlx-community/medgemma-1.5-4b-it-4bit")
        XCTAssertEqual(ModelCatalog.gemma4_E2B.repoID, "mlx-community/gemma-4-e2b-it-4bit")
    }

    func testTheDefaultChatModelIsUnchanged() {
        // Adding candidates must not move existing installs onto a multi-GB download.
        XCTAssertEqual(ModelCatalog.default, .qwen3_5_4B)
    }
}
