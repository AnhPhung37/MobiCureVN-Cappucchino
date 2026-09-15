import XCTest
import FoundationModels
@testable import MobiCureVN

/// `FoundationModelsService.generationOptions(for:)` is the one piece of the system-model
/// routing this suite can check without a device: the framework's real availability, streaming,
/// and safety-refusal behavior all need Apple Intelligence on the runner. Not run on this
/// session's Linux machine — verify on Mac/Xcode with a target that supports iOS 26.
@MainActor
final class FoundationModelsGenerationOptionsTests: XCTestCase {

    func testDeterministicPresetsAskForGreedySamplingNotTemperatureZero() {
        guard #available(iOS 26.0, *) else { return }
        // `.classification` and `.extraction` (GenerationOptions.swift) both carry temperature 0.
        let options = FoundationModelsService.generationOptions(
            for: GenerationOptions(maxTokens: 96, temperature: 0, topP: 1)
        )
        XCTAssertEqual(options.samplingMode, .greedy, "temperature 0 must become greedy sampling, not temperature: 0")
        XCTAssertNil(options.temperature, "greedy sampling and a temperature value are not set together")
        XCTAssertEqual(options.maximumResponseTokens, 96)
    }

    func testAnAnsweringPresetKeepsItsTemperature() {
        guard #available(iOS 26.0, *) else { return }
        // `.answer` (GenerationOptions.answer) carries InferenceTuning's sampling temperature.
        let options = FoundationModelsService.generationOptions(
            for: GenerationOptions(maxTokens: 512, temperature: 0.3, topP: 0.85)
        )
        XCTAssertNil(options.samplingMode, "a positive temperature is not paired with a sampling mode")
        XCTAssertEqual(options.temperature, 0.3, accuracy: 0.0001)
        XCTAssertEqual(options.maximumResponseTokens, 512)
    }

    func testTheMaximumResponseTokensCeilingAlwaysCarriesOver() {
        guard #available(iOS 26.0, *) else { return }
        // The token ceiling is the one backstop against a runaway reply on any backend
        // (MedicalChatOrchestrator's rationale for GenerationOptions in the first place);
        // it must survive translation regardless of which sampling branch is taken.
        for temperature: Float in [0, 0.1, 1] {
            let options = FoundationModelsService.generationOptions(
                for: GenerationOptions(maxTokens: 64, temperature: temperature, topP: 1)
            )
            XCTAssertEqual(options.maximumResponseTokens, 64, "temperature \(temperature)")
        }
    }
}
