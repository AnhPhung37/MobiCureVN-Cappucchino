import Foundation

/// Proposes durable, cross-conversation updates to the persisted `PatientProfile` from a single
/// user turn using the on-device LLM.
///
/// Unlike `SessionFactExtractor` (which extracts loose facts with no notion of existing state),
/// this extractor diffs against the *current confirmed profile* — so it can tell "new
/// information" from "already on file" and, critically, so it can withhold high-stakes clinical
/// fields (diagnosis, procedure, recovery stage) unless the user is stating an explicit
/// correction rather than just talking about symptoms.
///
/// Every proposal this produces is staged via `ProfileUpdateRepository` and requires explicit
/// patient confirmation before it ever touches the persisted profile — nothing here writes
/// directly. Mirrors `SessionFactExtractor`'s LLM conventions: a single
/// `LLMRequest(userMessage:)`, drain the stream, strip a Qwen `<think>` preamble, and fail
/// *closed* to an empty result on any parse trouble.
nonisolated struct ProfileUpdateExtractor {

    struct FieldProposal: Sendable, Equatable {
        enum Field: String, Sendable, Codable, CaseIterable {
            case name, age, gender, diagnosis, procedure, recoveryStage, reportSummary
            case currentWoundLocation = "wound_location"
            case careNoteAdd = "care_note_add"
            case warningSignAdd = "warning_sign_add"
            case allergyAdd = "allergy_add"
            case medicationAdd = "medication_add"
            case conditionAdd = "condition_add"

            /// Short, human-readable label for confirmation UI ("Diagnosis", "Care note", …).
            var displayLabel: String {
                switch self {
                case .name: return "Name"
                case .age: return "Age"
                case .gender: return "Gender"
                case .diagnosis: return "Diagnosis"
                case .procedure: return "Procedure"
                case .recoveryStage: return "Recovery stage"
                case .reportSummary: return "Report summary"
                case .currentWoundLocation: return "Current wound location"
                case .careNoteAdd: return "Care note"
                case .warningSignAdd: return "Warning sign"
                case .allergyAdd: return "Allergy"
                case .medicationAdd: return "Medication"
                case .conditionAdd: return "Condition"
                }
            }
        }

        let field: Field
        let newValue: String

        /// Diagnosis/procedure/recovery-stage edits get extra visual weight and safeguards in
        /// the confirmation UI — a wrong clinical field is far costlier than a wrong care note.
        var isHighStakes: Bool { field == .diagnosis || field == .procedure || field == .recoveryStage }
    }

    /// The field rules, minus any output-format instructions — the schema supplies those on the
    /// guided path. Developer-role content, so a message that quotes instructions (or names a
    /// field it wants set) can't override them.
    ///
    /// The `currentProfile` summary deliberately stays in the *user* turn rather than here: it is
    /// per-turn data, not a rule, and keeping instructions constant is what lets the framework
    /// reuse its prefix across calls.
    private static let guidedInstructions = """
    The patient has just sent a message. Identify any information about the patient that should \
    update their profile — ONLY when the user is explicitly stating a new fact about themselves, \
    a correction, or something a clinician told them. Do NOT propose a change for information \
    that already matches what's on file, general questions, greetings, or symptom talk that \
    isn't a stated fact.

    Field rules:
    - "diagnosis", "procedure", "recoveryStage" may ONLY be proposed when the user is stating an \
    EXPLICIT correction or a clinician-reported update (e.g. "my doctor changed my diagnosis \
    to...", "the surgery was actually a..."). NEVER infer these from symptoms, feelings, or \
    casual remarks.
    - "wound_location" replaces the current wound location.
    - "care_note_add", "warning_sign_add", "allergy_add", "medication_add", "condition_add" each \
    propose ADDING one new item to that list — never propose replacing or repeating the whole list.
    - "name", "age", "gender", "reportSummary" replace the current value.

    When nothing qualifies, return no updates at all rather than inventing any.
    """

    /// Propose zero or more profile-field updates from `userText`, given the profile currently
    /// on file. Returns `[]` when nothing durable/new is stated, when the model returns
    /// unparseable output, or when generation fails.
    func extract(
        from userText: String,
        currentProfile: PatientProfile,
        using llmService: LLMServiceProtocol
    ) async -> [FieldProposal] {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // Guided path — see the equivalent block in `SessionFactExtractor.extract` for the
        // rationale and the fallback contract.
        if #available(iOS 26.0, *), let structured = llmService as? any StructuredLLMService {
            if let extracted = try? await structured.respond(
                to: """
                The patient's CURRENT profile on file:
                \(Self.summarize(currentProfile))

                MESSAGE: \(trimmed)
                """,
                instructions: Self.guidedInstructions,
                generating: ExtractedProfileUpdates.self
            ) {
                return Self.proposals(from: extracted)
            }
        }

        let prompt = """
        The patient's CURRENT profile on file:
        \(Self.summarize(currentProfile))

        The patient just said the MESSAGE below. Identify any information about the patient \
        that should update their profile — ONLY when the user is explicitly stating a new fact \
        about themselves, a correction, or something a clinician told them. Do NOT propose a \
        change for information that already matches what's on file, general questions, \
        greetings, or symptom talk that isn't a stated fact.

        Field rules:
        - "diagnosis", "procedure", "recoveryStage" may ONLY be proposed when the user is \
        stating an EXPLICIT correction or a clinician-reported update (e.g. "my doctor changed \
        my diagnosis to...", "the surgery was actually a..."). NEVER infer these from symptoms, \
        feelings, or casual remarks.
        - "wound_location" replaces the current wound location.
        - "care_note_add", "warning_sign_add", "allergy_add", "medication_add", \
        "condition_add" each propose ADDING one new item to that list — never propose \
        replacing or repeating the whole list.
        - "name", "age", "gender", "reportSummary" replace the current value.

        Reply with a JSON array of objects, each having a "field" (one of: name, age, gender, \
        diagnosis, procedure, recoveryStage, reportSummary, wound_location, care_note_add, \
        warning_sign_add, allergy_add, medication_add, condition_add) and a "value". Keep each \
        value short. If nothing qualifies, reply with exactly [].

        Reply with ONLY the JSON array, nothing else.

        MESSAGE: \(trimmed)
        """

        let stream = llmService.stream(request: LLMRequest(userMessage: prompt))
        var reply = ""
        for await token in stream {
            reply += token
        }

        return Self.parse(reply)
    }

    // MARK: - Private

    /// Map a schema-constrained result onto `FieldProposal`. Reuses `field(named:)` so both paths
    /// resolve field names identically; the schema has already restricted generation to the known
    /// names, so the `nil` branch here is unreachable in practice rather than a real failure mode.
    @available(iOS 26.0, *)
    private static func proposals(from extracted: ExtractedProfileUpdates) -> [FieldProposal] {
        extracted.updates.compactMap { item in
            guard let field = field(named: item.field) else { return nil }
            let value = item.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            return FieldProposal(field: field, newValue: value)
        }
    }

    /// Compact, human-readable summary of the current profile for the extraction prompt —
    /// empty fields are omitted so a mostly-blank profile doesn't pad the prompt.
    private static func summarize(_ profile: PatientProfile) -> String {
        var lines: [String] = []
        func add(_ label: String, _ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            lines.append("- \(label): \(trimmed)")
        }
        if profile.age > 0 { lines.append("- Age: \(profile.age)") }
        add("Name", profile.name)
        add("Gender", profile.gender)
        add("Diagnosis", profile.diagnosis)
        add("Procedure", profile.procedure)
        add("Recovery stage", profile.recoveryStage)
        if let location = profile.currentWoundLocation { add("Current wound location", location) }
        if !profile.allergies.isEmpty { lines.append("- Allergies: \(profile.allergies.joined(separator: "; "))") }
        if !profile.medications.isEmpty { lines.append("- Medications: \(profile.medications.joined(separator: "; "))") }
        if !profile.conditions.isEmpty { lines.append("- Conditions: \(profile.conditions.joined(separator: "; "))") }
        return lines.isEmpty ? "[Nothing on file yet]" : lines.joined(separator: "\n")
    }

    /// Parse the model's reply into proposals. Tolerant by design, mirroring
    /// `SessionFactExtractor.parse(_:)`: strips a `<think>` preamble, isolates the first
    /// `[...]` array, decodes it, and drops any entry with an unrecognized field or empty
    /// value. Anything unparseable yields `[]`.
    static func parse(_ reply: String) -> [FieldProposal] {
        let cleaned = stripThinking(reply).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let json = firstJSONArray(in: cleaned),
              let data = json.data(using: .utf8) else { return [] }

        guard let raw = try? JSONDecoder().decode([RawProposal].self, from: data) else { return [] }

        return raw.compactMap { item in
            guard let field = field(named: item.field) else { return nil }
            let value = item.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            return FieldProposal(field: field, newValue: value)
        }
    }

    /// Resolve a model-emitted field name to a `Field`, ignoring case and `_`/`-` separators.
    /// A plain `Field(rawValue:)` is too strict in both directions: the camelCase raw values
    /// (`recoveryStage`, `reportSummary`) never survive lowercasing, and the snake_case ones
    /// (`wound_location`, `care_note_add`) are just as often emitted as `woundLocation`.
    /// Comparing on a separator-stripped, lowercased key matches every spelling the model
    /// actually produces.
    private static func field(named raw: String) -> FieldProposal.Field? {
        let key = normalize(raw)
        guard !key.isEmpty else { return nil }
        return FieldProposal.Field.allCases.first { normalize($0.rawValue) == key }
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// A model may emit a numeric age, so decode `value` leniently as string-or-number.
    private struct RawProposal: Decodable {
        let field: String
        let value: String

        enum CodingKeys: String, CodingKey { case field, value }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            field = (try? c.decode(String.self, forKey: .field)) ?? ""
            if let s = try? c.decode(String.self, forKey: .value) {
                value = s
            } else if let n = try? c.decode(Int.self, forKey: .value) {
                value = String(n)
            } else if let d = try? c.decode(Double.self, forKey: .value) {
                value = String(d)
            } else {
                value = ""
            }
        }
    }

    /// Extract the first top-level `[...]` substring, so surrounding prose doesn't break JSON
    /// decoding. Returns `nil` if no balanced array is found.
    private static func firstJSONArray(in text: String) -> String? {
        guard let start = text.firstIndex(of: "[") else { return nil }
        var depth = 0
        var index = start
        while index < text.endIndex {
            let ch = text[index]
            if ch == "[" { depth += 1 }
            else if ch == "]" {
                depth -= 1
                if depth == 0 {
                    return String(text[start...index])
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// Removes a `<think>…</think>` reasoning preamble Qwen-class models can emit even with
    /// thinking disabled. Mirrors `LanguageValidationService.stripThinking`.
    private static func stripThinking(_ reply: String) -> String {
        reply.replacingOccurrences(
            of: "(?s)<think>.*?(</think>|$)",
            with: "",
            options: .regularExpression
        )
    }
}
