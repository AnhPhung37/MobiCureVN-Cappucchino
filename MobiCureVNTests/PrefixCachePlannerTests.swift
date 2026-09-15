import XCTest
@testable import MobiCureVN

/// The decision rules of the prefix KV cache. Pure: no model, runs in milliseconds.
/// `PrefixCacheCorrectnessTests` checks the MLX half on a device.
@MainActor
final class PrefixCachePlannerTests: XCTestCase {

    private let minimum = PrefixCachePlanner.minimumPrefixTokens

    private func tokens(_ range: Range<Int>) -> [Int] { Array(range) }

    func testCommonPrefixLength() {
        XCTAssertEqual(PrefixCachePlanner.commonPrefixLength([1, 2, 3], [1, 2, 4]), 2)
        XCTAssertEqual(PrefixCachePlanner.commonPrefixLength([1, 2], [1, 2, 3]), 2)
        XCTAssertEqual(PrefixCachePlanner.commonPrefixLength([], [1]), 0)
        XCTAssertEqual(PrefixCachePlanner.commonPrefixLength([9], [1]), 0)
    }

    func testTheFirstTurnIsCold() {
        XCTAssertEqual(PrefixCachePlanner.decide(prompt: tokens(0 ..< 900), cachedPrefix: nil, previousPrompt: nil), .cold)
    }

    func testTheSecondTurnBuildsFromWhatTheTwoPromptsShare() {
        let previous = tokens(0 ..< 600) + [7, 7, 7]
        let current = tokens(0 ..< 600) + [8, 8]
        XCTAssertEqual(
            PrefixCachePlanner.decide(prompt: current, cachedPrefix: nil, previousPrompt: previous),
            .build(prefixLength: 600)
        )
    }

    func testAKeptPrefixIsReusedWhenThePromptStartsWithIt() {
        let prefix = tokens(0 ..< 600)
        XCTAssertEqual(
            PrefixCachePlanner.decide(prompt: prefix + [5, 6], cachedPrefix: prefix, previousPrompt: prefix + [1]),
            .reuse(prefixLength: 600)
        )
    }

    func testAChangedPrefixIsNeverReusedAndIsRebuiltFromTheNewSharedPart() {
        // Language switch or profile edit: the kept prefix no longer matches.
        let kept = tokens(0 ..< 600)
        let previous = [99] + tokens(1 ..< 700)
        let current = [99] + tokens(1 ..< 650) + [5, 5]
        XCTAssertEqual(
            PrefixCachePlanner.decide(prompt: current, cachedPrefix: kept, previousPrompt: previous),
            .build(prefixLength: 650)
        )
        XCTAssertNotEqual(
            PrefixCachePlanner.decide(prompt: current, cachedPrefix: kept, previousPrompt: nil),
            .reuse(prefixLength: 600)
        )
    }

    func testAPrefixThatIsTheWholePromptLeavesNothingToResumeFrom() {
        let prefix = tokens(0 ..< 600)
        XCTAssertEqual(PrefixCachePlanner.decide(prompt: prefix, cachedPrefix: prefix, previousPrompt: prefix), .cold)
    }

    func testShortSharedPrefixesAreNotKept() {
        let shared = tokens(0 ..< (minimum - 1))
        XCTAssertEqual(
            PrefixCachePlanner.decide(prompt: shared + [1, 2], cachedPrefix: nil, previousPrompt: shared + [3]),
            .cold
        )
        XCTAssertEqual(
            PrefixCachePlanner.decide(prompt: shared + [1, 2], cachedPrefix: shared, previousPrompt: nil),
            .cold
        )
    }

    func testEligibility() {
        func eligible(
            enabled: Bool = true, type: String? = "qwen3_5", system: Bool = true,
            media: Bool = false, afterMedia: Bool = false, bounded: Bool = false
        ) -> Bool {
            PrefixCachePlanner.isEligible(
                enabled: enabled, modelType: type, hasSystemPrompt: system,
                hasMedia: media, followsMedia: afterMedia, hasBoundedCache: bounded
            )
        }

        XCTAssertTrue(eligible())
        XCTAssertTrue(eligible(type: "llama"))
        XCTAssertFalse(eligible(enabled: false), "the tuning knob turns it off")
        XCTAssertFalse(eligible(system: false), "auxiliary passes must not evict the chat prefix")
        XCTAssertFalse(eligible(media: true))
        XCTAssertFalse(eligible(afterMedia: true), "Qwen3.5 rope state after an image turn")
        XCTAssertFalse(eligible(bounded: true), "rotating caches")
        XCTAssertFalse(eligible(type: "qwen2_5_vl"), "architectures not checked stay cold")
        XCTAssertFalse(eligible(type: nil))
    }

    func testTheCacheShipsOffUntilTheDeviceCheckPasses() {
        XCTAssertFalse(InferenceTuning.defaults.generation.prefixCache)
    }
}
