import XCTest
import Darwin
#if os(iOS)
import UIKit
#endif
@testable import MobiCureVN

/// End-to-end latency benchmark for success criterion #3 ("response generation time
/// should be under 5 seconds for text-based queries on the provided Mac Studio or iPad").
///
/// This is NOT part of the normal test run: it downloads and loads a multi-GB model and
/// takes minutes. It is skipped unless `MOBICURE_BENCH=1` is set, so CI and everyday
/// `⌘U` runs are unaffected.
///
/// Run it on each target device and keep the JSON — a criterion with no recorded
/// measurement is an unanswered criterion.
///
///     TEST_RUNNER_MOBICURE_BENCH=1 \
///     TEST_RUNNER_MOBICURE_BENCH_OUT=$PWD/Docs/benchmarks/latency-ipad-m5.json \
///     xcodebuild test -scheme MobiCureVN \
///       -destination 'platform=iOS,name=<iPad>' \
///       -only-testing:MobiCureVNTests/LatencyBenchmarkTests
///
/// See Docs/BE/Latency-Benchmark.md for the full procedure and what to report.
final class LatencyBenchmarkTests: XCTestCase {

    // MARK: - Configuration

    /// Queries are representative of real use, not cherry-picked short ones: a mix of
    /// languages and of short/long answers, because decode time dominates and scales with
    /// the answer length the question invites.
    private static let benchmarkQueries: [(id: String, text: String, language: DetectedLanguage)] = [
        ("en_short_01", "What is a stoma?", .english),
        ("en_short_02", "Can I shower with a stoma bag?", .english),
        ("en_medium_01", "What are the signs that my surgical wound is infected?", .english),
        ("en_medium_02", "What foods should I avoid after colorectal surgery?", .english),
        ("en_long_01", "Explain what to expect during recovery in the first six weeks after stoma reversal surgery.", .english),
        ("vi_short_01", "Hậu môn nhân tạo là gì?", .vietnamese),
        ("vi_short_02", "Tôi có thể tắm khi đang mang túi hậu môn nhân tạo không?", .vietnamese),
        ("vi_medium_01", "Làm sao để biết vết mổ của tôi bị nhiễm trùng?", .vietnamese),
        ("vi_medium_02", "Sau phẫu thuật ung thư đại trực tràng tôi nên kiêng ăn gì?", .vietnamese),
        ("vi_long_01", "Hãy giải thích quá trình hồi phục trong sáu tuần đầu sau khi đóng hậu môn nhân tạo.", .vietnamese),
    ]

    /// Discarded, not measured. The first generation after a model load pays for lazy
    /// weight paging and Metal pipeline compilation; reporting it as user-facing latency
    /// would overstate the steady state, hiding it entirely would understate cold start.
    /// So it is measured separately and reported as `coldStart`.
    private static let warmupQuery = "What is a colostomy?"

    /// Success criterion #3.
    private static let latencyBudgetSeconds: TimeInterval = 5.0

    // MARK: - Measurement

    private struct QueryLatency: Codable {
        let queryID: String
        let query: String
        let language: String
        /// Wall time from `processQuery` to the first `.preview` — what the user sees as
        /// "it started answering".
        let timeToFirstPreview: TimeInterval
        /// Wall time to the `.final` event — the guardrail-validated answer. This is the
        /// number criterion #3 is about.
        let timeToFinal: TimeInterval
        let previewEventCount: Int
        let answerCharacters: Int
    }

    private struct BenchmarkReport: Codable {
        let generatedAt: Date
        let device: String
        let osVersion: String
        let model: String
        let budgetSeconds: TimeInterval
        let coldStartSeconds: TimeInterval
        let modelLoadSeconds: TimeInterval
        let samples: [QueryLatency]
        let summary: Summary

        struct Summary: Codable {
            let count: Int
            let meanTimeToFinal: TimeInterval
            let medianTimeToFinal: TimeInterval
            let p95TimeToFinal: TimeInterval
            let maxTimeToFinal: TimeInterval
            let meanTimeToFirstPreview: TimeInterval
            let withinBudget: Int
            let budgetPassRate: Double
        }
    }

    func testEndToEndLatencyMeetsBudget() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MOBICURE_BENCH"] == "1",
            "Latency benchmark is opt-in: set MOBICURE_BENCH=1 (via xcodebuild: TEST_RUNNER_MOBICURE_BENCH=1). See Docs/BE/Latency-Benchmark.md"
        )

        // A mock backend would measure nothing but the harness itself, so refuse to
        // produce a report that looks real but is not.
        let modelID = ProcessInfo.processInfo.environment["MOBICURE_BENCH_MODEL"]
            ?? ModelCatalog.default.repoID

        // LLMService takes a LOCAL model directory, not a Hugging Face repo id: its init only
        // checks FileManager.fileExists(atPath:). Passing the repo id — as this test first did —
        // made isModelAvailable false, so every run skipped and no number was ever produced.
        // Resolve the path exactly as AppConfig.initializeLLMService does.
        let modelURL: URL? = ModelManager.shared.isModelDownloaded(repoID: modelID)
            ? try? ModelManager.shared.localModelURL(repoID: modelID)
            : nil
        guard let modelURL else {
            throw XCTSkip(
                "Model \(modelID) is not downloaded on this device. Download it from the app's "
                + "model picker first, then re-run."
            )
        }

        let loadStart = Date()
        let service = LLMService(modelPath: modelURL.path)
        let ready = await service.initializeModel()
        let modelLoadSeconds = Date().timeIntervalSince(loadStart)
        try XCTSkipUnless(
            ready,
            "Model \(modelID) failed to load — benchmark cannot run against the mock backend."
        )

        let orchestrator = MedicalChatOrchestrator(llmService: service)

        // Cold start: first real generation, measured but excluded from the steady-state summary.
        let cold = try await measure(
            query: Self.warmupQuery,
            id: "warmup",
            language: .english,
            orchestrator: orchestrator
        )

        var samples: [QueryLatency] = []
        for query in Self.benchmarkQueries {
            let sample = try await measure(
                query: query.text,
                id: query.id,
                language: query.language,
                orchestrator: orchestrator
            )
            samples.append(sample)
            print(String(
                format: "⏱️ %@  first-preview %.2fs  final %.2fs  (%d chars)",
                sample.queryID, sample.timeToFirstPreview, sample.timeToFinal, sample.answerCharacters
            ))
        }

        let report = makeReport(
            samples: samples,
            coldStart: cold.timeToFinal,
            modelLoadSeconds: modelLoadSeconds,
            model: modelID
        )
        try write(report)

        print(String(
            format: """

            ── Latency summary (budget %.1fs) ─────────────────────────
            model          %@
            cold start     %.2fs   (model load %.2fs)
            mean final     %.2fs
            median final   %.2fs
            p95 final      %.2fs
            max final      %.2fs
            within budget  %d/%d (%.0f%%)
            ───────────────────────────────────────────────────────────
            """,
            Self.latencyBudgetSeconds, modelID, report.coldStartSeconds, report.modelLoadSeconds,
            report.summary.meanTimeToFinal, report.summary.medianTimeToFinal,
            report.summary.p95TimeToFinal, report.summary.maxTimeToFinal,
            report.summary.withinBudget, report.summary.count,
            report.summary.budgetPassRate * 100
        ))

        // Assert on p95, not mean: a criterion about what users experience is not met by an
        // average that one fast query can carry.
        XCTAssertLessThan(
            report.summary.p95TimeToFinal,
            Self.latencyBudgetSeconds,
            """
            p95 time-to-final \(String(format: "%.2f", report.summary.p95TimeToFinal))s exceeds the \
            \(Self.latencyBudgetSeconds)s budget from success criterion #3. \
            Report the measured number rather than dropping the criterion.
            """
        )
    }

    // MARK: - Helpers

    private func measure(
        query: String,
        id: String,
        language: DetectedLanguage,
        orchestrator: MedicalChatOrchestrator
    ) async throws -> QueryLatency {
        let start = Date()
        var firstPreviewAt: Date?
        var previewCount = 0
        var finalText: String?

        let stream = orchestrator.processQuery(
            query,
            conversationHistory: [],
            conversationId: UUID(),
            responseLanguage: language
        )

        for await event in stream {
            switch event {
            case .preview:
                if firstPreviewAt == nil { firstPreviewAt = Date() }
                previewCount += 1
            case .final(let text):
                finalText = text
            }
        }

        let end = Date()
        let answer = try XCTUnwrap(finalText, "Stream for \(id) finished without a .final event")

        return QueryLatency(
            queryID: id,
            query: query,
            language: language == .vietnamese ? "vi" : "en",
            // A turn blocked by a guardrail yields `.final` with no preview; attributing the
            // whole turn to first-preview would be wrong, so fall back to the total.
            timeToFirstPreview: (firstPreviewAt ?? end).timeIntervalSince(start),
            timeToFinal: end.timeIntervalSince(start),
            previewEventCount: previewCount,
            answerCharacters: answer.count
        )
    }

    private func makeReport(
        samples: [QueryLatency],
        coldStart: TimeInterval,
        modelLoadSeconds: TimeInterval,
        model: String
    ) -> BenchmarkReport {
        let finals = samples.map(\.timeToFinal).sorted()
        let withinBudget = finals.filter { $0 < Self.latencyBudgetSeconds }.count

        func percentile(_ p: Double) -> TimeInterval {
            guard !finals.isEmpty else { return 0 }
            let rank = Int((p * Double(finals.count - 1)).rounded())
            return finals[min(max(rank, 0), finals.count - 1)]
        }

        let summary = BenchmarkReport.Summary(
            count: samples.count,
            meanTimeToFinal: finals.isEmpty ? 0 : finals.reduce(0, +) / Double(finals.count),
            medianTimeToFinal: percentile(0.5),
            p95TimeToFinal: percentile(0.95),
            maxTimeToFinal: finals.last ?? 0,
            meanTimeToFirstPreview: samples.isEmpty
                ? 0
                : samples.map(\.timeToFirstPreview).reduce(0, +) / Double(samples.count),
            withinBudget: withinBudget,
            budgetPassRate: samples.isEmpty ? 0 : Double(withinBudget) / Double(samples.count)
        )

        #if os(iOS)
        let device = UIDevice.current.model + " (" + Self.hardwareIdentifier() + ")"
        let os = UIDevice.current.systemVersion
        #else
        let device = Self.hardwareIdentifier()
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        #endif

        return BenchmarkReport(
            generatedAt: Date(),
            device: device,
            osVersion: os,
            model: model,
            budgetSeconds: Self.latencyBudgetSeconds,
            coldStartSeconds: coldStart,
            modelLoadSeconds: modelLoadSeconds,
            samples: samples,
            summary: summary
        )
    }

    /// e.g. "iPad16,6" / "Mac15,14" — the report has to name the hardware it ran on, since
    /// criterion #3 is stated per-device.
    ///
    /// The sysctl key differs by platform: on iOS the device identifier is `hw.machine`
    /// (`hw.model` returns an internal board id such as "D84AP"), while on Apple Silicon
    /// macOS it is `hw.model` (`hw.machine` returns just "arm64"). Reading the wrong one
    /// produces a report that cannot be attributed to a device.
    private static func hardwareIdentifier() -> String {
        #if os(iOS)
        let key = "hw.machine"
        #else
        let key = "hw.model"
        #endif
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &bytes, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: bytes)
    }

    private func write(_ report: BenchmarkReport) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)

        let path = ProcessInfo.processInfo.environment["MOBICURE_BENCH_OUT"]
            ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("latency-benchmark.json")
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
        print("📄 Latency report written to \(url.path)")

        // Also attach it to the test result, so a run on a physical device that cannot
        // write to the repo still surfaces the numbers in the Xcode report.
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "latency-benchmark.json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
