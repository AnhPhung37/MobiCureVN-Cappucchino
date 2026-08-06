import Foundation
import SwiftData

/// Single-row-per-install record: `id` is always `AppConfig.localPatientID`, matching the
/// app's single-user, single-profile model (see `SwiftDataProfileRepository`).
@Model
final class PatientProfileRecord {
    @Attribute(.unique) var id: UUID
    var name: String
    var age: Int
    var gender: String
    var diagnosis: String
    var procedure: String
    var recoveryStage: String
    var reportSummary: String
    /// JSON-encoded `[String]`, matching `ChatRecord`'s convention for array fields.
    var careNotesData: Data?
    var warningSignsData: Data?
    var allergiesData: Data?
    var medicationsData: Data?
    var conditionsData: Data?
    var currentWoundLocation: String?
    var sourceName: String
    var lastUpdated: Date

    init(
        id: UUID,
        name: String,
        age: Int,
        gender: String,
        diagnosis: String,
        procedure: String,
        recoveryStage: String,
        reportSummary: String,
        careNotesData: Data? = nil,
        warningSignsData: Data? = nil,
        allergiesData: Data? = nil,
        medicationsData: Data? = nil,
        conditionsData: Data? = nil,
        currentWoundLocation: String? = nil,
        sourceName: String,
        lastUpdated: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.age = age
        self.gender = gender
        self.diagnosis = diagnosis
        self.procedure = procedure
        self.recoveryStage = recoveryStage
        self.reportSummary = reportSummary
        self.careNotesData = careNotesData
        self.warningSignsData = warningSignsData
        self.allergiesData = allergiesData
        self.medicationsData = medicationsData
        self.conditionsData = conditionsData
        self.currentWoundLocation = currentWoundLocation
        self.sourceName = sourceName
        self.lastUpdated = lastUpdated
    }
}
