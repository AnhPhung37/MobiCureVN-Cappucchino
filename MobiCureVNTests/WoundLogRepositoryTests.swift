import XCTest
import SwiftData
@testable import MobiCureVN

/// Tests for SwiftDataWoundLogRepository and InMemoryWoundLogRepository — verifies both
/// conform to WoundLogRepository identically.
/// A new build passes if:
///   - Entries are persisted and reloaded with all fields intact
///   - loadEntries only returns entries for the requested patientID
///   - Entries are sorted by capturedAt ascending
///   - delete removes only the targeted entry
@MainActor
final class WoundLogRepositoryTests: XCTestCase {

    private func makeEntry(
        patientID: UUID,
        capturedAt: Date = Date(),
        stomaColor: String = "pink"
    ) -> WoundLogEntry {
        WoundLogEntry(
            patientID: patientID,
            capturedAt: capturedAt,
            imageReference: URL(fileURLWithPath: "/tmp/wound.jpg"),
            stomaColor: stomaColor,
            stomaSizeChange: "unchanged",
            surroundingSkin: "none observed",
            outputAppearance: "pasty",
            bagSeal: "intact",
            swellingOrProtrusion: "none",
            otherObservations: "no other findings",
            rawDescription: "STOMA_COLOR: pink\n...",
            modelUsed: "qwen2-vl-2b-instruct-4bit"
        )
    }

    private func makeSwiftDataRepository() throws -> SwiftDataWoundLogRepository {
        let schema = Schema([WoundLogRecord.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        return try SwiftDataWoundLogRepository(container: container)
    }

    // MARK: - SwiftDataWoundLogRepository

    func testSwiftDataRoundTripPreservesAllFields() async throws {
        let repo = try makeSwiftDataRepository()
        let patientID = UUID()
        let entry = makeEntry(patientID: patientID)

        try await repo.append(entry)
        let loaded = try await repo.loadEntries(patientID: patientID)

        XCTAssertEqual(loaded.count, 1)
        let result = try XCTUnwrap(loaded.first)
        XCTAssertEqual(result.id, entry.id)
        XCTAssertEqual(result.patientID, patientID)
        XCTAssertEqual(result.imageReference, entry.imageReference)
        XCTAssertEqual(result.stomaColor, entry.stomaColor)
        XCTAssertEqual(result.stomaSizeChange, entry.stomaSizeChange)
        XCTAssertEqual(result.surroundingSkin, entry.surroundingSkin)
        XCTAssertEqual(result.outputAppearance, entry.outputAppearance)
        XCTAssertEqual(result.bagSeal, entry.bagSeal)
        XCTAssertEqual(result.swellingOrProtrusion, entry.swellingOrProtrusion)
        XCTAssertEqual(result.otherObservations, entry.otherObservations)
        XCTAssertEqual(result.rawDescription, entry.rawDescription)
        XCTAssertEqual(result.flaggedForReview, entry.flaggedForReview)
        XCTAssertEqual(result.modelUsed, entry.modelUsed)
    }

    func testSwiftDataFiltersByPatientID() async throws {
        let repo = try makeSwiftDataRepository()
        let patientA = UUID()
        let patientB = UUID()

        try await repo.append(makeEntry(patientID: patientA))
        try await repo.append(makeEntry(patientID: patientB))

        let loadedA = try await repo.loadEntries(patientID: patientA)
        let loadedB = try await repo.loadEntries(patientID: patientB)

        XCTAssertEqual(loadedA.count, 1)
        XCTAssertEqual(loadedB.count, 1)
        XCTAssertEqual(loadedA.first?.patientID, patientA)
        XCTAssertEqual(loadedB.first?.patientID, patientB)
    }

    func testSwiftDataSortsByCapturedAtAscending() async throws {
        let repo = try makeSwiftDataRepository()
        let patientID = UUID()
        let now = Date()

        let older = makeEntry(patientID: patientID, capturedAt: now.addingTimeInterval(-3600), stomaColor: "older")
        let newer = makeEntry(patientID: patientID, capturedAt: now, stomaColor: "newer")

        try await repo.append(newer)
        try await repo.append(older)

        let loaded = try await repo.loadEntries(patientID: patientID)

        XCTAssertEqual(loaded.map(\.stomaColor), ["older", "newer"])
    }

    func testSwiftDataDeleteRemovesOnlyTargetedEntry() async throws {
        let repo = try makeSwiftDataRepository()
        let patientID = UUID()
        let keep = makeEntry(patientID: patientID, stomaColor: "keep")
        let remove = makeEntry(patientID: patientID, stomaColor: "remove")

        try await repo.append(keep)
        try await repo.append(remove)
        try await repo.delete(id: remove.id)

        let loaded = try await repo.loadEntries(patientID: patientID)

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.stomaColor, "keep")
    }

    // MARK: - InMemoryWoundLogRepository

    func testInMemoryRoundTripAndFiltering() async throws {
        let repo = InMemoryWoundLogRepository()
        let patientA = UUID()
        let patientB = UUID()

        try await repo.append(makeEntry(patientID: patientA))
        try await repo.append(makeEntry(patientID: patientB))

        let loadedA = try await repo.loadEntries(patientID: patientA)
        XCTAssertEqual(loadedA.count, 1)
        XCTAssertEqual(loadedA.first?.patientID, patientA)
    }

    func testInMemoryDeleteRemovesEntry() async throws {
        let repo = InMemoryWoundLogRepository()
        let patientID = UUID()
        let entry = makeEntry(patientID: patientID)

        try await repo.append(entry)
        try await repo.delete(id: entry.id)

        let loaded = try await repo.loadEntries(patientID: patientID)
        XCTAssertTrue(loaded.isEmpty)
    }
}
