import XCTest
import SwiftData
@testable import MobiCureVN

/// Tests for SwiftDataProfileRepository and InMemoryProfileRepository — verifies both conform to
/// ProfileRepository identically, and that the profile carries one stable identity for the life
/// of the install.
/// A new build passes if:
///   - fetchProfile seeds a blank profile instead of failing or fabricating clinical data
///   - the profile id equals the patient id it was opened with, and does NOT change between
///     fetches (the regenerated-id bug that decoupled the profile from the wound log)
///   - save round-trips every field, including the JSON-encoded [String] arrays
///   - save upserts rather than inserting a second row
@MainActor
final class ProfileRepositoryTests: XCTestCase {

    private func makeSwiftDataRepository(patientID: UUID) throws -> SwiftDataProfileRepository {
        let schema = Schema([PatientProfileRecord.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        return try SwiftDataProfileRepository(container: container, patientID: patientID)
    }

    private func makePopulatedProfile(id: UUID) -> PatientProfile {
        PatientProfile(
            id: id,
            name: "Nguyen Van A",
            age: 52,
            gender: "Male",
            diagnosis: "Colorectal cancer",
            procedure: "Sigmoid colectomy with colostomy",
            recoveryStage: "Early recovery",
            reportSummary: "Stable recovery after surgery.",
            careNotes: ["Keep the wound clean and dry.", "Drink enough water."],
            warningSigns: ["Fever or chills", "Pus at the wound"],
            allergies: ["Penicillin"],
            medications: ["Paracetamol"],
            conditions: ["Type 2 diabetes"],
            currentWoundLocation: "Left lower abdomen",
            sourceName: "Discharge summary"
        )
    }

    // MARK: - Stable identity

    func testFetchSeedsBlankProfileWithThePatientID() async throws {
        let patientID = UUID()
        let repo = try makeSwiftDataRepository(patientID: patientID)

        let profile = try await repo.fetchProfile()

        XCTAssertEqual(profile.id, patientID)
        // Blank, not fabricated — an AI proposal must never be able to "confirm a change to"
        // clinical data the patient never supplied.
        XCTAssertEqual(profile.name, "")
        XCTAssertEqual(profile.age, 0)
        XCTAssertEqual(profile.diagnosis, "")
        XCTAssertTrue(profile.careNotes.isEmpty)
        XCTAssertTrue(profile.warningSigns.isEmpty)
    }

    func testProfileIDIsStableAcrossFetches() async throws {
        let patientID = UUID()
        let repo = try makeSwiftDataRepository(patientID: patientID)

        let first = try await repo.fetchProfile()
        let second = try await repo.fetchProfile()

        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(second.id, patientID)
    }

    func testProfileIDSurvivesSaveOfAProfileCarryingADifferentID() async throws {
        let patientID = UUID()
        let repo = try makeSwiftDataRepository(patientID: patientID)
        _ = try await repo.fetchProfile()

        // A caller handing over a profile built with a fresh UUID must not be able to fork the
        // single-profile row — the repository owns the identity, not the incoming struct.
        try await repo.save(makePopulatedProfile(id: UUID()))

        let reloaded = try await repo.fetchProfile()
        XCTAssertEqual(reloaded.id, patientID)
        XCTAssertEqual(reloaded.name, "Nguyen Van A")
    }

    // MARK: - Round trip

    func testSaveRoundTripPreservesAllFields() async throws {
        let patientID = UUID()
        let repo = try makeSwiftDataRepository(patientID: patientID)
        let profile = makePopulatedProfile(id: patientID)

        try await repo.save(profile)
        let loaded = try await repo.fetchProfile()

        XCTAssertEqual(loaded.id, patientID)
        XCTAssertEqual(loaded.name, profile.name)
        XCTAssertEqual(loaded.age, profile.age)
        XCTAssertEqual(loaded.gender, profile.gender)
        XCTAssertEqual(loaded.diagnosis, profile.diagnosis)
        XCTAssertEqual(loaded.procedure, profile.procedure)
        XCTAssertEqual(loaded.recoveryStage, profile.recoveryStage)
        XCTAssertEqual(loaded.reportSummary, profile.reportSummary)
        XCTAssertEqual(loaded.sourceName, profile.sourceName)
        XCTAssertEqual(loaded.currentWoundLocation, profile.currentWoundLocation)
        // The JSON-encoded [String] columns — the fields most likely to break silently.
        XCTAssertEqual(loaded.careNotes, profile.careNotes)
        XCTAssertEqual(loaded.warningSigns, profile.warningSigns)
        XCTAssertEqual(loaded.allergies, profile.allergies)
        XCTAssertEqual(loaded.medications, profile.medications)
        XCTAssertEqual(loaded.conditions, profile.conditions)
    }

    func testRepeatedSavesUpsertRatherThanAccumulate() async throws {
        let patientID = UUID()
        let schema = Schema([PatientProfileRecord.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let repo = try SwiftDataProfileRepository(container: container, patientID: patientID)

        _ = try await repo.fetchProfile()
        try await repo.save(makePopulatedProfile(id: patientID))
        try await repo.save(makePopulatedProfile(id: patientID))

        let records = try container.mainContext.fetch(FetchDescriptor<PatientProfileRecord>())
        XCTAssertEqual(records.count, 1, "save must upsert the single profile row, not insert a new one")
    }

    func testSaveWithoutAPriorFetchStillCreatesTheRow() async throws {
        let patientID = UUID()
        let repo = try makeSwiftDataRepository(patientID: patientID)

        try await repo.save(makePopulatedProfile(id: patientID))

        let loaded = try await repo.fetchProfile()
        XCTAssertEqual(loaded.diagnosis, "Colorectal cancer")
    }

    // MARK: - InMemory parity

    func testInMemoryRepositoryMatchesSwiftDataBehavior() async throws {
        let patientID = UUID()
        let repo = InMemoryProfileRepository(patientID: patientID)

        let seeded = try await repo.fetchProfile()
        XCTAssertEqual(seeded.id, patientID)
        XCTAssertEqual(seeded.name, "")

        try await repo.save(makePopulatedProfile(id: patientID))
        let loaded = try await repo.fetchProfile()
        XCTAssertEqual(loaded.id, patientID)
        XCTAssertEqual(loaded.diagnosis, "Colorectal cancer")
        XCTAssertEqual(loaded.warningSigns, ["Fever or chills", "Pus at the wound"])
    }
}

/// Tests that the persisted profile actually reaches the retrieval stage — and, just as
/// importantly, that a patient who has never filled one in gets the pipeline's previous behavior.
final class PatientProfilePersonalizationTests: XCTestCase {

    func testRetrievalTermsCarryTheClinicalFields() {
        let profile = PatientProfile(
            name: "Nguyen Van A",
            age: 52,
            gender: "Male",
            diagnosis: "Colorectal cancer",
            procedure: "Sigmoid colectomy with colostomy",
            recoveryStage: "Early recovery",
            reportSummary: "Stable recovery after surgery.",
            careNotes: ["Keep the wound clean and dry."],
            warningSigns: ["Fever or chills"],
            currentWoundLocation: "Left lower abdomen",
            sourceName: "Discharge summary"
        )

        let terms = MedicalChatOrchestrator.retrievalTerms(profile)

        XCTAssertEqual(terms, ["Colorectal cancer", "Sigmoid colectomy with colostomy", "Left lower abdomen"])
        // Advice already given to the patient is not a description of their condition, so it
        // must not bias what gets retrieved.
        XCTAssertFalse(terms.contains { $0.contains("clean and dry") })
        XCTAssertFalse(terms.contains { $0.contains("Fever") })
    }

    func testBlankProfileContributesNoRetrievalTerms() {
        let blank = PatientProfile(
            name: "", age: 0, gender: "", diagnosis: "", procedure: "",
            recoveryStage: "", reportSummary: "", careNotes: [], warningSigns: [],
            sourceName: "No clinician report on file yet"
        )

        XCTAssertTrue(MedicalChatOrchestrator.retrievalTerms(blank).isEmpty)
    }

    func testWhitespaceOnlyFieldsAreTreatedAsBlank() {
        let profile = PatientProfile(
            name: "A", age: 1, gender: "", diagnosis: "   ", procedure: "\n",
            recoveryStage: "", reportSummary: "", careNotes: [], warningSigns: [],
            currentWoundLocation: "  ",
            sourceName: ""
        )

        XCTAssertTrue(MedicalChatOrchestrator.retrievalTerms(profile).isEmpty)
    }

    func testDuplicateFieldsAreNotRepeated() {
        let profile = PatientProfile(
            name: "A", age: 1, gender: "", diagnosis: "Colostomy", procedure: "colostomy",
            recoveryStage: "", reportSummary: "", careNotes: [], warningSigns: [],
            sourceName: ""
        )

        XCTAssertEqual(MedicalChatOrchestrator.retrievalTerms(profile), ["Colostomy"])
    }
}
