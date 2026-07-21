import Foundation

protocol WoundLogRepository {
    func loadEntries(patientID: UUID) async throws -> [WoundLogEntry]
    func append(_ entry: WoundLogEntry) async throws
    func delete(id: UUID) async throws
}
