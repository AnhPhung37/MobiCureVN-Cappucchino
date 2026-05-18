import Foundation

struct PatientProfile: Identifiable, Sendable {
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
        self.sourceName = sourceName
        self.lastUpdated = lastUpdated
    }
}
