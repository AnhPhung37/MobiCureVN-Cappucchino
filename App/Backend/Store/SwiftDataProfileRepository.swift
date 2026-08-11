import Foundation
import SwiftData

/// Persists the single patient profile this device ever has, keyed to `patientID`
/// (defaults to `AppConfig.localPatientID`). `fetchProfile()` seeds a blank placeholder row on
/// first call rather than returning fabricated data — see the seeding note below.
@MainActor
final class SwiftDataProfileRepository: ProfileRepository {

    private let container: ModelContainer
    private let patientID: UUID

    init(container: ModelContainer? = nil, patientID: UUID = AppConfig.localPatientID) throws {
        if let container {
            self.container = container
        } else {
            // Full schema: this store is shared with ChatRecord/WoundLogRecord. Prefer
            // AppConfig.modelContainer at call sites — see the note on AppConfig.modelContainer.
            self.container = try ModelContainer(for: ChatRecord.self, WoundLogRecord.self, PatientProfileRecord.self)
        }
        self.patientID = patientID
    }

    func fetchProfile() async throws -> PatientProfile {
        if let record = try fetchRecord() {
            return Self.profile(from: record)
        }

        // No report has been ingested yet and nothing has been confirmed from chat: seed a
        // blank row rather than fabricated clinical data, which would be actively misleading
        // in a medical app (the AI could then "confirm changes to" content that was never real).
        let seed = PatientProfileRecord(
            id: patientID,
            name: "",
            age: 0,
            gender: "",
            diagnosis: "",
            procedure: "",
            recoveryStage: "",
            reportSummary: "",
            sourceName: "No clinician report on file yet"
        )
        container.mainContext.insert(seed)
        try container.mainContext.save()
        return Self.profile(from: seed)
    }

    func save(_ profile: PatientProfile) async throws {
        let record = try fetchRecord() ?? {
            let newRecord = PatientProfileRecord(
                id: patientID, name: "", age: 0, gender: "", diagnosis: "", procedure: "",
                recoveryStage: "", reportSummary: "", sourceName: ""
            )
            container.mainContext.insert(newRecord)
            return newRecord
        }()

        record.name = profile.name
        record.age = profile.age
        record.gender = profile.gender
        record.diagnosis = profile.diagnosis
        record.procedure = profile.procedure
        record.recoveryStage = profile.recoveryStage
        record.reportSummary = profile.reportSummary
        record.careNotesData = Self.encode(profile.careNotes)
        record.warningSignsData = Self.encode(profile.warningSigns)
        record.allergiesData = Self.encode(profile.allergies)
        record.medicationsData = Self.encode(profile.medications)
        record.conditionsData = Self.encode(profile.conditions)
        record.currentWoundLocation = profile.currentWoundLocation
        record.photoData = profile.photoData
        record.sourceName = profile.sourceName
        record.lastUpdated = profile.lastUpdated

        try container.mainContext.save()
    }

    // MARK: - Private

    private func fetchRecord() throws -> PatientProfileRecord? {
        let target = patientID
        let predicate = #Predicate<PatientProfileRecord> { $0.id == target }
        var descriptor = FetchDescriptor<PatientProfileRecord>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try container.mainContext.fetch(descriptor).first
    }

    private static func profile(from record: PatientProfileRecord) -> PatientProfile {
        PatientProfile(
            id: record.id,
            name: record.name,
            age: record.age,
            gender: record.gender,
            diagnosis: record.diagnosis,
            procedure: record.procedure,
            recoveryStage: record.recoveryStage,
            reportSummary: record.reportSummary,
            careNotes: decode(record.careNotesData),
            warningSigns: decode(record.warningSignsData),
            allergies: decode(record.allergiesData),
            medications: decode(record.medicationsData),
            conditions: decode(record.conditionsData),
            currentWoundLocation: record.currentWoundLocation,
            photoData: record.photoData,
            sourceName: record.sourceName,
            lastUpdated: record.lastUpdated
        )
    }

    private static func decode(_ data: Data?) -> [String] {
        guard let data else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    private static func encode(_ strings: [String]) -> Data? {
        try? JSONEncoder().encode(strings)
    }
}
