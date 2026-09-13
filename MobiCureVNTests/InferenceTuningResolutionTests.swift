import XCTest
@testable import MobiCureVN

/// Pins how `InferenceTuning` resolves its configuration: built-in defaults ← bundled JSON ←
/// Documents JSON, where a seed the app wrote and nobody edited does not count as a layer.
///
/// The bug behind this file: the Documents copy was seeded with every value on first launch and
/// then always won, so every later change to the bundled defaults was silently ignored on any
/// device that had run the app once — including the test host.
final class InferenceTuningResolutionTests: XCTestCase {

    private typealias Shape = InferenceTuning.FileShape

    /// What `seedDocumentsCopyIfMissing` writes for `tuning`.
    private func seed(of tuning: InferenceTuning) -> Shape {
        var shape = tuning.fileShape
        shape.profileName = "device-local (edit me, then relaunch)"
        shape.seedFingerprint = shape.valuesFingerprint
        return shape
    }

    func testTheBundledFileDescribesTheSameAppAsTheCompiledDefaults() throws {
        let url = try XCTUnwrap(
            Bundle.main.url(forResource: InferenceTuning.filename, withExtension: InferenceTuning.fileExtension),
            "InferenceTuning.json must ship in the app bundle"
        )
        let bundled = try JSONDecoder().decode(Shape.self, from: Data(contentsOf: url))
        XCTAssertEqual(
            bundled.resolved().fileShape.valuesFingerprint,
            InferenceTuning.defaults.fileShape.valuesFingerprint,
            "App/Resources/InferenceTuning.json and InferenceTuning.defaults have drifted apart"
        )
    }

    func testWithNoFilesTheCompiledDefaultsApply() {
        let result = InferenceTuning.layer(bundle: nil, documents: nil)
        XCTAssertEqual(result.source, .builtInDefaults)
        XCTAssertEqual(result.tuning.fileShape.valuesFingerprint, InferenceTuning.defaults.fileShape.valuesFingerprint)
        XCTAssertFalse(result.replaceStaleSeed)
    }

    func testTheBundleOverridesOnlyTheKeysItSets() {
        let result = InferenceTuning.layer(bundle: Shape(prompt: .init(contextTokenBudget: 1234)), documents: nil)
        XCTAssertEqual(result.source, .bundle)
        XCTAssertEqual(result.tuning.prompt.contextTokenBudget, 1234)
        XCTAssertEqual(result.tuning.prompt.historyTokenBudget, InferenceTuning.defaults.prompt.historyTokenBudget)
    }

    func testAnEditedDocumentsFileOverridesTheBundleKeyByKey() {
        let bundle = Shape(prompt: .init(contextTokenBudget: 1234, historyTokenBudget: 400))
        let documents = Shape(prompt: .init(historyTokenBudget: 300))
        let result = InferenceTuning.layer(bundle: bundle, documents: documents)
        XCTAssertEqual(result.source, .documentsOverride)
        XCTAssertEqual(result.tuning.prompt.historyTokenBudget, 300, "the device's own edit wins")
        XCTAssertEqual(
            result.tuning.prompt.contextTokenBudget, 1234,
            "a key the device did not set comes from the bundle, not from the compiled defaults"
        )
    }

    func testAnUneditedSeedFromAnEarlierBuildDoesNotFreezeTheNewDefaults() {
        // The shipped bug: a device seeded while the bundle said 600 kept running 600 after the
        // bundle moved to 2000.
        var olderBuild = InferenceTuning.defaults.fileShape
        olderBuild.prompt?.contextTokenBudget = 600
        let staleSeed = seed(of: olderBuild.resolved())

        let result = InferenceTuning.layer(bundle: Shape(prompt: .init(contextTokenBudget: 2000)), documents: staleSeed)
        XCTAssertEqual(result.tuning.prompt.contextTokenBudget, 2000)
        XCTAssertEqual(result.source, .bundle)
        XCTAssertTrue(result.replaceStaleSeed, "the stale seed is rewritten so the file on the device shows what runs")
    }

    func testASeedThatMatchesWhatRunsIsLeftAlone() {
        let bundle = Shape(prompt: .init(contextTokenBudget: 2000))
        let current = seed(of: InferenceTuning.layer(bundle: bundle, documents: nil).tuning)
        let result = InferenceTuning.layer(bundle: bundle, documents: current)
        XCTAssertFalse(result.replaceStaleSeed)
        XCTAssertEqual(result.tuning.prompt.contextTokenBudget, 2000)
    }

    func testEditingAValueInTheSeedTurnsItIntoAnOverride() {
        // Exactly what the test protocol's "knob is live" check does on a device.
        var edited = seed(of: InferenceTuning.defaults)
        edited.prompt?.contextTokenBudget = 800
        XCTAssertFalse(edited.isUneditedSeed)

        let result = InferenceTuning.layer(bundle: nil, documents: edited)
        XCTAssertEqual(result.source, .documentsOverride)
        XCTAssertEqual(result.tuning.prompt.contextTokenBudget, 800)
    }

    func testRenamingTheProfileIsNotAnEdit() {
        var renamed = seed(of: InferenceTuning.defaults)
        renamed.profileName = "my sweep"
        XCTAssertTrue(renamed.isUneditedSeed)
    }

    func testTheFingerprintSurvivesTheRoundTripThroughTheFile() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let decoded = try JSONDecoder().decode(Shape.self, from: encoder.encode(seed(of: InferenceTuning.defaults)))
        XCTAssertTrue(decoded.isUneditedSeed, "a seed read back from disk must still be recognised as unedited")
    }

    func testTheRatioOverrideIsOptionalAndClamped() {
        XCTAssertNil(Shape().resolved().prompt.wordsToTokensRatio, "no override keeps the per-model ratio")
        XCTAssertEqual(Shape(prompt: .init(wordsToTokensRatio: 0.5)).resolved().prompt.wordsToTokensRatio, 1.0)
    }
}
