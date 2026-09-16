import XCTest
@testable import MobiCureVN

/// Tests for the RAG context packing in `MedicalChatOrchestrator.applyContextBudget`.
///
/// The bug these lock down shipped silently for months: the packer used `break`, so one
/// oversized chunk at rank 1 discarded every chunk behind it and the model was handed no
/// sources at all on 22.5% of golden-set queries. See Docs/BE/Context-Budget-Finding.md.
///
/// Every test passes an explicit ratio, so the arithmetic is independent of which model the
/// test host happens to have selected.
@MainActor
final class ContextBudgetTests: XCTestCase {

    /// 1.5 tokens per word: a chunk of N words costs ceil(1.5 × N).
    private let ratio = 1.5

    private func chunk(
        id: String,
        words: Int,
        source: String? = nil,
        separator: String = " "
    ) -> ContextChunk {
        ContextChunk(
            id: id,
            content: Array(repeating: "word", count: words).joined(separator: separator),
            section: "Section \(id)",
            sourceID: source ?? "src_\(id)",
            relevanceScore: 1.0
        )
    }

    private func pack(_ chunks: [ContextChunk], budget: Int) -> [ContextChunk] {
        MedicalChatOrchestrator.applyContextBudget(chunks, budget: budget, ratio: ratio)
    }

    private func cost(_ chunks: [ContextChunk], ratio: Double? = nil) -> Int {
        chunks
            .map { MedicalChatOrchestrator.estimateTokens($0.content, ratio: ratio ?? self.ratio) }
            .reduce(0, +)
    }

    // MARK: - The regression

    func testAnOversizedChunkDoesNotDiscardTheChunksBehindIt() {
        // The shipped bug in miniature: a huge chunk first, small usable ones after. The small
        // chunks must survive even when enough budget is left over for a partial of the huge
        // one — the first fix spent that remainder first and dropped them.
        let chunks = [chunk(id: "huge", words: 10_000), chunk(id: "a", words: 50), chunk(id: "b", words: 50)]
        let kept = pack(chunks, budget: 400)
        XCTAssertEqual(kept.map(\.id), ["huge", "a", "b"], "small chunks survive; the huge one contributes only its head")
        XCTAssertTrue(kept[0].content.hasSuffix("[…]"))
        XCTAssertLessThanOrEqual(cost(kept), 400)
    }

    func testSmallChunksSurviveWhenNoPartialFitsEither() {
        // Both 10-word chunks fit (15 tokens each); the 40 left is below the partial-fill floor.
        let chunks = [chunk(id: "huge", words: 10_000), chunk(id: "a", words: 10), chunk(id: "b", words: 10)]
        XCTAssertEqual(pack(chunks, budget: 70).map(\.id), ["a", "b"])
    }

    func testTheModelIsNeverHandedZeroContextWhenSomethingFits() {
        let kept = pack([chunk(id: "huge", words: 10_000), chunk(id: "small", words: 10)], budget: 300)
        XCTAssertFalse(kept.isEmpty, "retrieval succeeded; the prompt must not say 'no context found'")
    }

    // MARK: - Partial fill

    func testRemainingBudgetIsSpentOnTheHeadOfAChunkThatDoesNotFit() {
        let kept = pack([chunk(id: "huge", words: 10_000)], budget: 800)
        XCTAssertEqual(kept.count, 1)
        XCTAssertTrue(kept[0].content.hasSuffix("[…]"), "a trimmed passage must be marked as cut")
        XCTAssertLessThanOrEqual(cost(kept), 800)
        XCTAssertGreaterThan(cost(kept), 800 - 3, "the head uses the remainder, not a timid fraction of it")
    }

    func testATrimmedChunkKeepsItsIdentityForCitation() {
        let kept = pack([chunk(id: "huge", words: 10_000)], budget: 800)
        XCTAssertEqual(kept.first?.id, "huge")
        XCTAssertEqual(kept.first?.sourceID, "src_huge")
        XCTAssertEqual(kept.first?.section, "Section huge")
    }

    func testATinyRemainderIsLeftUnspentRatherThanSendingAFragment() {
        // 60 words = 90 tokens; the 10 left would carry a torn sentence that grounds nothing.
        let kept = pack([chunk(id: "fill", words: 60), chunk(id: "huge", words: 10_000)], budget: 100)
        XCTAssertEqual(kept.map(\.id), ["fill"])
    }

    func testAPartialChunkKeepsItsRankPosition() {
        let kept = pack(
            [chunk(id: "a", words: 20), chunk(id: "huge", words: 10_000), chunk(id: "b", words: 20)],
            budget: 300
        )
        XCTAssertEqual(kept.map(\.id), ["a", "huge", "b"])
        XCTAssertLessThanOrEqual(cost(kept), 300)
    }

    func testOnlyTheHighestRankedChunkThatDidNotFitIsCut() {
        let kept = pack([chunk(id: "first", words: 10_000), chunk(id: "second", words: 10_000)], budget: 800)
        XCTAssertEqual(kept.map(\.id), ["first"])
    }

    // MARK: - The budget is a ceiling

    func testLineBreaksAreCountedTheWayTheEstimateCountsThem() {
        // Regression: the cut used to split on " " only, so a newline-separated passage looked
        // like a single word to the cut and came back whole, far over budget.
        let kept = pack([chunk(id: "lines", words: 1_000, separator: "\n")], budget: 200)
        XCTAssertEqual(kept.count, 1)
        XCTAssertLessThanOrEqual(cost(kept), 200)
    }

    func testTheCutKeepsTheOriginalLineStructure() {
        let text = (1...200).map { "Line \($0) of the care guidance." }.joined(separator: "\n")
        let kept = pack([ContextChunk(id: "c", content: text, section: "S", sourceID: "d", relevanceScore: 1)], budget: 150)
        XCTAssertEqual(kept.count, 1)
        let head = String(kept[0].content.dropLast(" […]".count))
        XCTAssertTrue(head.contains("\n"), "list structure inside the head must survive the cut")
        XCTAssertTrue(text.hasPrefix(head), "the head is a verbatim prefix of the passage")
    }

    func testPackingNeverExceedsTheBudgetAndIsIdempotent() {
        var generator = SeededGenerator(seed: 0x5EED)
        let separators = [" ", "\n", "  ", "\n\n", "\t"]
        for _ in 0..<300 {
            var chunks: [ContextChunk] = []
            for index in 0..<Int.random(in: 1...8, using: &generator) {
                var content = "w"
                for _ in 1..<Int.random(in: 1...900, using: &generator) {
                    content += separators.randomElement(using: &generator)! + "w"
                }
                chunks.append(ContextChunk(id: "\(index)", content: content, section: "", sourceID: "d\(index)", relevanceScore: 1))
            }
            let budget = Int.random(in: 0...3_000, using: &generator)
            let ratio = [1.0, 1.5, 1.65, 1.75, 2.85].randomElement(using: &generator)!

            let kept = MedicalChatOrchestrator.applyContextBudget(chunks, budget: budget, ratio: ratio)
            XCTAssertLessThanOrEqual(cost(kept, ratio: ratio), budget)
            let repacked = MedicalChatOrchestrator.applyContextBudget(kept, budget: budget, ratio: ratio)
            XCTAssertEqual(repacked.map(\.content), kept.map(\.content), "packing an already-packed context changes nothing")
        }
    }

    // MARK: - What the rest of the turn is told

    func testPackedSourcesNameOnlyDocumentsTheModelReads() {
        let chunks = [
            chunk(id: "a", words: 40, source: "docA"),
            chunk(id: "b", words: 40, source: "docB"),
            chunk(id: "c", words: 40, source: "docC"),
        ]
        let sources = ["docA", "docB", "docC"].map {
            MedicalSource(id: $0, title: $0, excerpt: "", page: 1, documentName: $0)
        }
        let context = RetrievedContext(chunks: chunks, confidenceScore: 0.8, sources: sources)

        // 60 tokens each: two fit in 130, and the 10 left is below the partial-fill floor.
        let packed = MedicalChatOrchestrator.packed(context, budget: 130, ratio: ratio)
        XCTAssertEqual(packed.chunks.map(\.id), ["a", "b"])
        XCTAssertEqual(packed.sources.map(\.id), ["docA", "docB"], "a citation must not name a document the model never read")
        XCTAssertEqual(packed.confidenceScore, 0.8)
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

    // MARK: - The tuning the fix depends on

    func testContextBudgetAndTopKShipTogether() {
        // The budget used to be a hardcoded 600 shadowing the JSON value, making the knob dead.
        // InferenceTuningResolutionTests pins that the bundled JSON agrees with these defaults.
        XCTAssertEqual(InferenceTuning.defaults.prompt.retrievalTopK, 10)
        XCTAssertEqual(InferenceTuning.defaults.prompt.contextTokenBudget, 3000)
    }

    func testTopKAndContextBudgetAreRaisedTogether() {
        // Measured (Docs/BE/Context-Budget-Finding.md, Qwen 3.5 ratio): topK 10 grounds 0.7512 at a
        // 2000 budget and 0.8134 at 3000. Past five chunks the budget decides how much of the extra
        // retrieval reaches the model, so a raised topK must ship with a budget that carries it.
        let prompt = InferenceTuning.defaults.prompt
        if prompt.retrievalTopK > 5 {
            XCTAssertGreaterThanOrEqual(
                prompt.contextTokenBudget, 3000,
                "topK > 5 needs a budget that can actually carry the extra chunks"
            )
        }
    }

    func testTheShippedRatioIsPerModelRatherThanGlobal() {
        XCTAssertNil(InferenceTuning.defaults.prompt.wordsToTokensRatio)
    }

    func testEveryShippedModelCarriesItsMeasuredRatio() {
        for model in ModelCatalog.allCases {
            XCTAssertGreaterThanOrEqual(model.wordsToTokensRatio, 1.0, "\(model) has no measured ratio")
        }
        // Pipeline/tools/measure_token_ratio.py — see Docs/BE/Context-Budget-Finding.md.
        // The Phi-3.5 Mini spot check (2.85) went with the model when the catalog was
        // narrowed to Qwen 3.5 4B; the loop above still covers every case that ships.
        XCTAssertEqual(ModelCatalog.qwen3_5_4B.wordsToTokensRatio, 1.75)
    }
}

/// SplitMix64, so the randomized packing test is reproducible run to run.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
