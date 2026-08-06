import Foundation

extension PatientProfile {
    /// Returns the profile with an accepted proposal applied. Replace-fields overwrite; the
    /// additive `*Add` fields append (skipping an exact duplicate already present). Never
    /// called for a proposal the patient hasn't explicitly confirmed — see
    /// `ProfileUpdateRepository`.
    func applying(_ update: ProposedProfileUpdate) -> PatientProfile {
        switch update.field {
        case .name: return with(name: update.newValue)
        case .age: return with(age: Int(update.newValue) ?? age)
        case .gender: return with(gender: update.newValue)
        case .diagnosis: return with(diagnosis: update.newValue)
        case .procedure: return with(procedure: update.newValue)
        case .recoveryStage: return with(recoveryStage: update.newValue)
        case .reportSummary: return with(reportSummary: update.newValue)
        case .currentWoundLocation: return with(currentWoundLocation: update.newValue)
        case .careNoteAdd: return with(careNotes: appending(update.newValue, to: careNotes))
        case .warningSignAdd: return with(warningSigns: appending(update.newValue, to: warningSigns))
        case .allergyAdd: return with(allergies: appending(update.newValue, to: allergies))
        case .medicationAdd: return with(medications: appending(update.newValue, to: medications))
        case .conditionAdd: return with(conditions: appending(update.newValue, to: conditions))
        }
    }

    private func appending(_ value: String, to list: [String]) -> [String] {
        list.contains(value) ? list : list + [value]
    }

    private func with(
        name: String? = nil,
        age: Int? = nil,
        gender: String? = nil,
        diagnosis: String? = nil,
        procedure: String? = nil,
        recoveryStage: String? = nil,
        reportSummary: String? = nil,
        careNotes: [String]? = nil,
        warningSigns: [String]? = nil,
        allergies: [String]? = nil,
        medications: [String]? = nil,
        conditions: [String]? = nil,
        currentWoundLocation: String? = nil
    ) -> PatientProfile {
        PatientProfile(
            id: id,
            name: name ?? self.name,
            age: age ?? self.age,
            gender: gender ?? self.gender,
            diagnosis: diagnosis ?? self.diagnosis,
            procedure: procedure ?? self.procedure,
            recoveryStage: recoveryStage ?? self.recoveryStage,
            reportSummary: reportSummary ?? self.reportSummary,
            careNotes: careNotes ?? self.careNotes,
            warningSigns: warningSigns ?? self.warningSigns,
            allergies: allergies ?? self.allergies,
            medications: medications ?? self.medications,
            conditions: conditions ?? self.conditions,
            currentWoundLocation: currentWoundLocation ?? self.currentWoundLocation,
            sourceName: sourceName,
            lastUpdated: Date()
        )
    }
}
