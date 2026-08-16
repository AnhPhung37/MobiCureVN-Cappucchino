import Foundation

/// A single field update the AI proposed from something the patient said in chat, staged for
/// explicit confirmation before it ever touches the persisted `PatientProfile`.
///
/// No `patientID`: this is a single-profile-per-device app (see `AppConfig.localPatientID`),
/// so every proposal implicitly belongs to the one profile on this device — carrying an id
/// that's always the same value would just be dead weight.
struct ProposedProfileUpdate: Identifiable, Sendable, Equatable {
    let id: UUID
    /// Which conversation surfaced this — for the source-excerpt trail, not a scoping key.
    let conversationId: UUID
    let field: ProfileUpdateExtractor.FieldProposal.Field
    let newValue: String
    /// Snapshot of the field's value at proposal time, for audit/display. `nil` for the
    /// additive `*Add` fields (there's no single "previous value" for a list append) and for
    /// fields that were blank on the profile.
    let previousValue: String?
    let isHighStakes: Bool
    /// The triggering user message, truncated — shown alongside the proposal so the patient
    /// can see exactly what prompted it.
    let sourceExcerpt: String
    let createdAt: Date
    var status: Status

    enum Status: String, Sendable, Equatable { case pending, accepted, dismissed }

    init(
        id: UUID = UUID(),
        conversationId: UUID,
        field: ProfileUpdateExtractor.FieldProposal.Field,
        newValue: String,
        previousValue: String?,
        isHighStakes: Bool,
        sourceExcerpt: String,
        createdAt: Date = Date(),
        status: Status = .pending
    ) {
        self.id = id
        self.conversationId = conversationId
        self.field = field
        self.newValue = newValue
        self.previousValue = previousValue
        self.isHighStakes = isHighStakes
        self.sourceExcerpt = sourceExcerpt
        self.createdAt = createdAt
        self.status = status
    }

    /// Builds a proposal from a raw extractor output, filling in `previousValue`/
    /// `isHighStakes` from the profile the extraction was diffed against.
    init(
        proposal: ProfileUpdateExtractor.FieldProposal,
        currentProfile: PatientProfile,
        conversationId: UUID,
        sourceExcerpt: String
    ) {
        self.init(
            conversationId: conversationId,
            field: proposal.field,
            newValue: proposal.newValue,
            previousValue: Self.previousValue(for: proposal.field, in: currentProfile),
            isHighStakes: proposal.isHighStakes,
            sourceExcerpt: sourceExcerpt
        )
    }

    private static func previousValue(
        for field: ProfileUpdateExtractor.FieldProposal.Field,
        in profile: PatientProfile
    ) -> String? {
        switch field {
        case .name: return profile.name.isEmpty ? nil : profile.name
        case .age: return profile.age > 0 ? String(profile.age) : nil
        case .gender: return profile.gender.isEmpty ? nil : profile.gender
        case .diagnosis: return profile.diagnosis.isEmpty ? nil : profile.diagnosis
        case .procedure: return profile.procedure.isEmpty ? nil : profile.procedure
        case .recoveryStage: return profile.recoveryStage.isEmpty ? nil : profile.recoveryStage
        case .reportSummary: return profile.reportSummary.isEmpty ? nil : profile.reportSummary
        case .currentWoundLocation: return profile.currentWoundLocation
        case .careNoteAdd, .warningSignAdd, .allergyAdd, .medicationAdd, .conditionAdd:
            return nil
        }
    }
}
