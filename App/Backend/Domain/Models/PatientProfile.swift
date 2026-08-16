import Foundation

struct PatientProfile: Identifiable, Sendable {
    /// Equal to `AppConfig.localPatientID` for the one real (persisted) profile this
    /// single-user app ever has. Mock/preview repositories may still pass an arbitrary id.
    let id: UUID
    let name: String
    let age: Int
    let gender: String
    let diagnosis: String
    let procedure: String
    let recoveryStage: String
    let reportSummary: String
    let careNotes: [String]
    let warningSigns: [String]
    let allergies: [String]
    let medications: [String]
    let conditions: [String]
    let currentWoundLocation: String?
    /// Patient-chosen avatar, JPEG-encoded via `UIImage.attachmentJPEGData()` (so it's already
    /// downscaled). Only ever set by the patient editing their own profile — the AI proposal
    /// path has no field for it, since a photo isn't something a chat turn can state.
    let photoData: Data?
    let sourceName: String
    let lastUpdated: Date

    init(
        id: UUID = UUID(),
        name: String,
        age: Int,
        gender: String,
        diagnosis: String,
        procedure: String,
        recoveryStage: String,
        reportSummary: String,
        careNotes: [String],
        warningSigns: [String],
        allergies: [String] = [],
        medications: [String] = [],
        conditions: [String] = [],
        currentWoundLocation: String? = nil,
        photoData: Data? = nil,
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
        self.careNotes = careNotes
        self.warningSigns = warningSigns
        self.allergies = allergies
        self.medications = medications
        self.conditions = conditions
        self.currentWoundLocation = currentWoundLocation
        self.photoData = photoData
        self.sourceName = sourceName
        self.lastUpdated = lastUpdated
    }
}
