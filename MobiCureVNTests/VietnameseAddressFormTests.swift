import XCTest
@testable import MobiCureVN

/// Locks the Vietnamese forms of address in the answer prompt: the assistant calls itself "tôi"
/// and the person it is talking to "bạn".
///
/// With no instruction the model chose a pair per turn — "bạn–mình", "em–bạn", even "em–em".
/// Nothing anchored the choice: the patient's message reaches the model already translated to
/// English, so there is no Vietnamese register to mirror, and the "caring nurse" persona pulls
/// toward the kinship pronouns a Vietnamese nurse would use. Replayed history then carried
/// whichever pair an earlier turn happened to pick.
///
/// Keyword assertions, like SystemPromptConstraintTests: they prove the rule sits where the model
/// reads it, not that the model obeys it. Obedience is checked on device with case 7.8 of
/// `Docs/BE/Adversarial-Chat-Test-Script.md`.
@MainActor
final class VietnameseAddressFormTests: XCTestCase {

    /// In-memory stores, as in PrefixStabilityTests: prompt building is pure string assembly.
    private let orchestrator = MedicalChatOrchestrator(
        llmService: MockLLMService(),
        factStore: SessionFactStore(),
        profileRepository: InMemoryProfileRepository(patientID: UUID()),
        profileUpdateStore: InMemoryProfileUpdateRepository()
    )

    private func prompt(answeringIn language: DetectedLanguage) -> MedicalChatOrchestrator.EnrichedPrompt {
        let chunk = ContextChunk(
            id: "a", content: "Keep the wound clean and dry.", section: "Wound care",
            sourceID: "src_a", relevanceScore: 0.9
        )
        let context = RetrievedContext(chunks: [chunk], confidenceScore: 0.8, sources: [])
        return orchestrator.buildEnrichedPrompt(
            userQuery: "How do I care for my wound?",
            context: context,
            history: [],
            responseLanguage: language
        )
    }

    /// The two positions the orchestrator's own notes say a small model attends to: the opening
    /// LANGUAGE line and the closing REMINDER after the retrieved context.
    private func openingDirective(_ prompt: MedicalChatOrchestrator.EnrichedPrompt) -> String {
        prompt.stablePrefix.components(separatedBy: "\n").first ?? ""
    }

    private func closingReminder(_ prompt: MedicalChatOrchestrator.EnrichedPrompt) -> String {
        prompt.volatileSuffix.components(separatedBy: "REMINDER").last ?? ""
    }

    func testVietnameseAnswersAreToldToUseTôiAndBạnAtBothEndsOfThePrompt() {
        for language in [DetectedLanguage.vietnamese, .mixed] {
            let built = prompt(answeringIn: language)
            for (position, text) in [("opening directive", openingDirective(built)),
                                     ("closing reminder", closingReminder(built))] {
                XCTAssertTrue(text.contains("\"tôi\""), "\(language) \(position) does not say to use “tôi”: \(text)")
                XCTAssertTrue(text.contains("\"bạn\""), "\(language) \(position) does not say to use “bạn”: \(text)")
            }
        }
    }

    func testVietnameseAnswersRuleOutTheFormsTheModelDriftedInto() {
        // "Use tôi/bạn" alone left the model free to mirror an "em" or "mình" from the patient's
        // own wording or from an earlier reply in the replayed history — the observed failures.
        let prefix = prompt(answeringIn: .vietnamese).stablePrefix
        for form in ["\"mình\"", "\"em\""] {
            XCTAssertTrue(prefix.contains(form), "Vietnamese prompt does not rule out \(form)")
        }
    }

    func testEnglishAnswersCarryNoVietnameseAddressRule() {
        // The rule costs prefill tokens on every turn it is sent; an English answer has no use
        // for it, and Vietnamese pronouns in an English prompt invite code-switching.
        let system = prompt(answeringIn: .english).systemPrompt
        for form in ["\"tôi\"", "\"bạn\"", "\"mình\"", "\"em\""] {
            XCTAssertFalse(system.contains(form), "English prompt mentions \(form)")
        }
    }
}
