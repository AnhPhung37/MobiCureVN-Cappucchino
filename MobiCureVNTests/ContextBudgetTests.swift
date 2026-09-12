import XCTest
@testable import MobiCureVN

/// Tests for the RAG context packing in `MedicalChatOrchestrator.applyContextBudget`.
///
/// The bug these lock down shipped silently for months: the packer used `break`, so one
/// oversized chunk at rank 1 discarded every chunk behind it and the model was handed no
/// sources at all on 22.5% of golden-set queries. See Docs/BE/Context-Budget-Finding.md.
final class ContextBudgetTests: XCTestCase {

    /// `estimateTokens` is words × `wordsToTokensRatio`, so word counts are the unit
    /// these tests think in.
    private func chunk(id: String, words: Int, score: Double = 1.0) -> ContextChunk {
        ContextChunk(
            id: id,
            content: Array(repeating: "word", count: words).joined(separator: " "),
            section: "Section \(id)",
            sourceID: "src_\(id)",
            relevanceScore: score
        )
    }

    private func pack(_ chunks: [ContextChunk], budget: Int) -> [ContextChunk] {
        MedicalChatOrchestrator.applyContextBudget(chunks, budget: budget)
    }

    // MARK: - The regression

    func testAnOversizedChunkDoesNotDiscardTheChunksBehindIt() {
        // The shipped bug in miniature. The budget is deliberately below
        // minimumUsefulChunkTokens, so the huge chunk cannot be partially filled and must be
        // SKIPPED — under the old `break` this returned nothing at all.
        //
        // When the remainder IS large enough, the partial fill of the higher-ranked chunk takes
        // precedence and packing stops (see testPackingStopsOnceTheBudgetIsSpentOnAPartialChunk).
        // An earlier version of this test assumed the opposite and would have failed on first
        // compile; the measured grounding numbers were always computed against the real
        // behaviour.
        let chunks = [chunk(id: "huge", words: 10_000), chunk(id: "a", words: 10), chunk(id: "b", words: 10)]
        let kept = pack(chunks, budget: 70)
        XCTAssertEqual(kept.map(\.id), ["a", "b"], "small chunks behind a huge one must survive")
    }

    func testTheModelIsNeverHandedZeroContextWhenSomethingFits() {
        let kept = pack([chunk(id: "huge", words: 10_000), chunk(id: "small", words: 10)], budget: 300)
        XCTAssertFalse(kept.isEmpty, "retrieval succeeded; the prompt must not say 'no context found'")
    }

    // MARK: - Partial fill

    func testRemainingBudgetIsSpentOnTheHeadOfAChunkThatDoesNotFit() {
        // One chunk, far too large, but plenty of budget to carry a useful head.
        let kept = pack([chunk(id: "huge", words: 10_000)], budget: 800)
        XCTAssertEqual(kept.count, 1)
        XCTAssertTrue(kept[0].content.hasSuffix("[…]"), "a trimmed passage must be marked as cut")
        XCTAssertLessThan(kept[0].content.split(separator: " ").count, 10_000)
    }

    func testATrimmedChunkKeepsItsIdentityForCitation() {
        let kept = pack([chunk(id: "huge", words: 10_000)], budget: 800)
        XCTAssertEqual(kept.first?.id, "huge")
        XCTAssertEqual(kept.first?.sourceID, "src_huge")
        XCTAssertEqual(kept.first?.section, "Section huge")
    }

    func testATinyRemainderIsLeftUnspentRatherThanSendingAFragment() {
        // 3 words of remaining budget: a torn sentence reads as authoritative and grounds nothing.
        let kept = pack([chunk(id: "fill", words: 60), chunk(id: "huge", words: 10_000)], budget: 100)
        XCTAssertEqual(kept.map(\.id), ["fill"])
    }

    func testPackingStopsOnceTheBudgetIsSpentOnAPartialChunk()  {
        let kept = pack(
            [chunk(id: "huge", words: 10_000), chunk(id: "after", words: 5)],
            budget: 800
        )
        XCTAssertEqual(kept.map(\.id), ["huge"], "the budget is spent; nothing more may be appended")
    }

    // MARK: - Ordinary behaviour

    func testChunksAreKeptInRelevanceOrder() {
        let kept = pack([chunk(id: "a", words: 20), chunk(id: "b", words: 20), chunk(id: "c", words: 20)], budget: 400)
        XCTAssertEqual(kept.map(\.id), ["a", "b", "c"])
    }

    func testEverythingFitsWhenTheBudgetIsAmple() {
        let chunks = (1...5).map { chunk(id: "\($0)", words: 30) }
        XCTAssertEqual(pack(chunks, budget: 10_000).count, 5)
    }

    func testZeroBudgetSelectsNothing() {
        XCTAssertTrue(pack([chunk(id: "a", words: 10)], budget: 0).isEmpty)
    }

    func testEmptyInputSelectsNothing() {
        XCTAssertTrue(pack([], budget: 1000).isEmpty)
    }

    // MARK: - The tuning knobs the fix depends on

    func testContextBudgetIsReadFromTuningNotHardcoded() {
        // It used to be a hardcoded 600 shadowing the JSON value, making the knob dead.
        XCTAssertGreaterThanOrEqual(InferenceTuning.current.prompt.contextTokenBudget, 2000)
    }

    func testTopKAndContextBudgetAreRaisedTogether() {
        // Measured: topK 10 at a 2000-token budget grounds exactly as well as topK 5 --
        // the budget binds first. Shipping a raised topK against a small budget spends
        // retrieval time for nothing, so the two are asserted as a pair.
        let prompt = InferenceTuning.current.prompt
        if prompt.retrievalTopK > 5 {
            XCTAssertGreaterThanOrEqual(
                prompt.contextTokenBudget, 3000,
                "topK > 5 needs a budget that can actually carry the extra chunks"
            )
        }
    }

    func testTokenRatioIsCalibratedAgainstTheCorpus() {
        // Measured median across all 1238 chunks is 1.554 tokens/word; 1.4 under-estimated
        // 62.6% of them. See Docs/BE/Context-Budget-Finding.md.
        XCTAssertGreaterThanOrEqual(InferenceTuning.current.prompt.wordsToTokensRatio, 1.6)
    }
}
