import Foundation

/// Fallback used when `AppConfig.modelContainer` fails to open, and in unit tests. Seeds the
/// same blank placeholder as `SwiftDataProfileRepository` rather than fabricated data.
actor InMemoryProfileRepository: ProfileRepository {
    private var stored: PatientProfile?
    private let patientID: UUID

    init(patientID: UUID = AppConfig.localPatientID) {
        self.patientID = patientID
    }

    func fetchProfile() async throws -> PatientProfile {
        if let stored { return stored }
        let seed = PatientProfile(
            id: patientID,
            name: "",
            age: 0,
            gender: "",
            diagnosis: "",
            procedure: "",
            recoveryStage: "",
            reportSummary: "",
            careNotes: [],
            warningSigns: [],
            sourceName: "No clinician report on file yet"
        )
        stored = seed
        return seed
    }

    func save(_ profile: PatientProfile) async throws {
        stored = profile
    }
}
