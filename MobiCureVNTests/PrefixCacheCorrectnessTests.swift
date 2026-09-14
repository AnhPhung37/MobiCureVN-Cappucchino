import XCTest
@testable import MobiCureVN

/// The check that must pass before `generation.prefixCache` is turned on: a resumed generation says
/// the same thing as a cold one.
///
/// A mis-seeded cache does not crash — it produces fluent, wrong text — so this compares output, not
/// just that something was generated. Greedy decoding makes both runs deterministic; the resumed run
/// prefills in different chunks, so floating-point noise can flip a near-tie many tokens in, which is
/// why only the opening words are compared. A wrong cache diverges from the first words.
///
/// Loads a multi-GB model; skipped unless `MOBICURE_BENCH=1`, like `LatencyBenchmarkTests`:
///
///     TEST_RUNNER_MOBICURE_BENCH=1 xcodebuild test -scheme MobiCureVN \
///       -destination 'platform=iOS,name=<iPad>' \
///       -only-testing:MobiCureVNTests/PrefixCacheCorrectnessTests
@MainActor
final class PrefixCacheCorrectnessTests: XCTestCase {

    private static let comparedWords = 12

    private static let questions = [
        "What is a stoma?",
        "Can I shower with a stoma bag?",
        "What are the signs that my surgical wound is infected?",
    ]

    /// The shipped persona as the shared prefix, and a per-turn tail standing in for retrieved context.
    private static func systemPrompt(turn: Int) -> String {
        "LANGUAGE: Respond ONLY in English.\n\n" + MedicalChatOrchestrator.invariantSystemPrompt
            + "\n\nRetrieved Medical Context:\n[Turn \(turn)]\nPassage number \(turn) about stoma care."
    }

    private func modelPath() throws -> String {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MOBICURE_BENCH"] == "1",
            "Set MOBICURE_BENCH=1 to run the prefix cache device check."
        )
        let modelID = ProcessInfo.processInfo.environment["MOBICURE_BENCH_MODEL"] ?? ModelCatalog.default.repoID
        guard ModelManager.shared.isModelDownloaded(repoID: modelID),
              let url = try? ModelManager.shared.localModelURL(repoID: modelID) else {
            throw XCTSkip("\(modelID) is not downloaded")
        }
        return url.path
    }

    private func answers(path: String, prefixCache: Bool) async throws -> (texts: [String], stats: PrefixCacheStats) {
        let service = LLMService(modelPath: path, prefixCache: prefixCache)
        let ready = await service.initializeModel()
        try XCTSkipUnless(ready, "MLX could not load the model")
        defer { service.unload() }

        var texts: [String] = []
        for (turn, question) in Self.questions.enumerated() {
            let request = LLMRequest(
                systemPrompt: Self.systemPrompt(turn: turn),
                userMessage: question,
                options: GenerationOptions(maxTokens: 40, temperature: 0, topP: 1)
            )
            var text = ""
            for await chunk in service.stream(request: request) {
                text += chunk
            }
            texts.append(text)
        }
        return (texts, service.prefixCacheStats)
    }

    private static func opening(_ text: String) -> [Substring] {
        Array(text.split(whereSeparator: \.isWhitespace).prefix(comparedWords))
    }

    func testResumedGenerationSaysWhatColdGenerationSays() async throws {
        let path = try modelPath()
        let cold = try await answers(path: path, prefixCache: false)
        let warm = try await answers(path: path, prefixCache: true)

        XCTAssertEqual(cold.stats, PrefixCacheStats(), "a disabled cache records nothing")
        XCTAssertEqual(warm.stats.cold, 1, "turn 1 has nothing to share")
        XCTAssertEqual(warm.stats.built, 1, "turn 2 keeps the shared persona")
        XCTAssertEqual(warm.stats.reused, 1, "turn 3 resumes from it")
        XCTAssertGreaterThan(warm.stats.reusedTokens, PrefixCachePlanner.minimumPrefixTokens)

        for turn in cold.texts.indices {
            XCTAssertFalse(warm.texts[turn].isEmpty)
            XCTAssertEqual(
                Self.opening(warm.texts[turn]), Self.opening(cold.texts[turn]),
                "turn \(turn + 1): resumed output differs from cold — the cache is mis-seeded; keep prefixCache off"
            )
        }
    }
}
