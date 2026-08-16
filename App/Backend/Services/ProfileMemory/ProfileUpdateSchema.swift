//
//  ProfileUpdateSchema.swift
//  MobiCureVN
//

import Foundation
import FoundationModels

/// Schema for the guided-generation path of `ProfileUpdateExtractor`.
///
/// The field list is spelled out as literals rather than derived from
/// `ProfileUpdateExtractor.FieldProposal.Field.allCases` so the macro sees a plain array
/// expression. `ProfileUpdateSchemaTests` asserts the two stay in step — drift would silently
/// drop proposals for the missing field, which is exactly the failure this path exists to remove.
///
/// Note what `.anyOf` does NOT cover: it constrains the field *name*, not whether proposing that
/// field is appropriate. The high-stakes rules (diagnosis/procedure/recoveryStage only on an
/// explicit correction) remain prompt-level instructions, and the staging-plus-confirmation flow
/// in `ProfileUpdateRepository` is still what actually protects the persisted profile.
@available(iOS 26.0, *)
@Generable
struct ExtractedProfileUpdates {
    @Guide(
        description: """
        Every profile field the patient's message gives new or corrected information for. \
        Empty when nothing qualifies.
        """,
        .maximumCount(6)
    )
    var updates: [ExtractedProfileUpdate]
}

@available(iOS 26.0, *)
@Generable
struct ExtractedProfileUpdate {
    @Guide(
        description: "Which profile field this updates.",
        .anyOf([
            "name", "age", "gender", "diagnosis", "procedure", "recoveryStage",
            "reportSummary", "wound_location", "care_note_add", "warning_sign_add",
            "allergy_add", "medication_add", "condition_add"
        ])
    )
    var field: String

    @Guide(description: "The new value, in as few words as possible. English.")
    var value: String
}
