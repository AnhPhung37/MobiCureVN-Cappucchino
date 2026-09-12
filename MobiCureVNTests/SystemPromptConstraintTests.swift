import XCTest
@testable import MobiCureVN

/// Locks the safety constraints in `MedicalChatOrchestrator.invariantSystemPrompt`.
///
/// That prompt is re-read by the model on every turn, so its length is a per-turn latency tax
/// and there is standing pressure to shorten it. Shortening is fine; **dropping a rule is not**.
/// Each test below pins one behavioural requirement, so a future edit that removes it fails
/// here rather than in front of a patient.
///
/// These are keyword assertions, not behaviour tests — they prove the instruction is still in
/// the prompt, not that the model obeys it. Obedience is validated separately against
/// `Docs/BE/Adversarial-Chat-Test-Script.md`, which must be re-run after any edit to this prompt.
final class SystemPromptConstraintTests: XCTestCase {

    private var prompt: String { MedicalChatOrchestrator.invariantSystemPrompt.lowercased() }

    private func assertMentions(
        _ needles: [String],
        _ requirement: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let found = needles.contains { prompt.contains($0.lowercased()) }
        XCTAssertTrue(
            found,
            "System prompt no longer expresses: \(requirement). Looked for any of \(needles).",
            file: file,
            line: line
        )
    }

    // MARK: - Clinical safety

    func testStatesItIsNotAPhysician() {
        assertMentions(["not a licensed physician", "not a physician"],
                       "the assistant is not a licensed physician")
    }

    func testForbidsDiagnosisAndTreatmentPlans() {
        assertMentions(["no diagnosis", "cannot provide medical diagnosis"],
                       "no diagnosis or treatment plans")
    }

    func testForbidsConfidentDosageRecommendations() {
        assertMentions(["dosage"], "never recommend specific dosages confidently")
    }

    func testRequiresEmergencyEscalation() {
        assertMentions(["emergency services"],
                       "emergency symptoms must escalate to emergency services")
    }

    func testRequiresAHealthcareProviderDisclaimer() {
        assertMentions(["healthcare provider"],
                       "advice carries a consult-your-provider disclaimer")
    }

    // MARK: - Grounding and attribution

    func testRequiresCitingSources() {
        assertMentions(["cite your sources", "always cite"],
                       "medical information must be cited")
    }

    func testPrefersRetrievedContextAsPrimarySource() {
        assertMentions(["primary source"],
                       "retrieved context is the primary source")
    }

    // MARK: - The rule that matters most for this corpus

    func testForbidsAssertingUnstatedProceduresAsThePatientsOwn() {
        // The corpus is general colorectal guidance, not this patient's record. Asserting a
        // stoma or a procedure the patient never mentioned is the highest-consequence
        // hallucination this app can produce.
        assertMentions(["not this patient's record", "unless they said so"],
                       "retrieved context must not be asserted as the patient's own situation")
    }

    func testRequiresConditionalFramingForUnmentionedProcedures() {
        assertMentions(["conditional", "if you have a stoma"],
                       "guidance about unmentioned procedures stays conditional")
    }

    func testRequiresWarningSignsToBeScopedToTheProcedure() {
        assertMentions(["red flag", "warning sign"],
                       "a procedure-specific red flag is not issued as a general alarm")
    }

    func testRequiresAClarifyingQuestionWhenTheAnswerDependsOnTheProcedure() {
        assertMentions(["clarifying question"],
                       "ask one clarifying question rather than guessing")
    }

    // MARK: - Tone and scope

    func testDoesNotRefuseNonClinicalTurnsColdly() {
        assertMentions(["do not refuse coldly", "don't refuse coldly", "refuse coldly"],
                       "off-topic turns are redirected warmly, not refused")
    }

    func testAcknowledgesAndRemembersSharedPersonalDetails() {
        assertMentions(["remember it for the rest", "remember them for the rest"],
                       "personal details are acknowledged and remembered")
    }

    func testTreatsVagueFollowUpsAsContinuations() {
        assertMentions(["is that normal", "follow-up"],
                       "vague follow-ups continue the current topic")
    }

    // MARK: - Budget

    func testPromptStaysWithinItsBudget() {
        // Not a style rule: this string is re-prefilled every turn. If it grows back past its
        // original size the latency work is undone. Raise this deliberately, never by accident.
        let words = MedicalChatOrchestrator.invariantSystemPrompt
            .split(whereSeparator: \.isWhitespace).count
        XCTAssertLessThanOrEqual(
            words, 340,
            "Invariant system prompt grew to \(words) words. It was slimmed from 473 to ~305 "
            + "to cut ~268 tokens of prefill per turn; re-justify before raising this bound."
        )
    }
}
