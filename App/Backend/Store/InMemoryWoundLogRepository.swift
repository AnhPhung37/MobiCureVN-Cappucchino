import Foundation

actor InMemoryWoundLogRepository: WoundLogRepository {
    private var entries: [WoundLogEntry] = []

    func loadEntries(patientID: UUID) async throws -> [WoundLogEntry] {
        entries
            .filter { $0.patientID == patientID }
            .sorted { $0.capturedAt < $1.capturedAt }
    }

    func append(_ entry: WoundLogEntry) async throws {
        entries.append(entry)
    }

    func delete(id: UUID) async throws {
        entries.removeAll { $0.id == id }
    }
}
