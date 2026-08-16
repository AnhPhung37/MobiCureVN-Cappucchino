import Foundation
import SwiftData

@MainActor
final class SwiftDataProfileUpdateRepository: ProfileUpdateRepository {

    private let container: ModelContainer

    init(container: ModelContainer? = nil) throws {
        if let container {
            self.container = container
        } else {
            // Full schema — prefer AppConfig.modelContainer at call sites, see the note there.
            self.container = try ModelContainer(
                for: ChatRecord.self, WoundLogRecord.self, PatientProfileRecord.self, ProposedProfileUpdateRecord.self
            )
        }
    }

    func listPending() async throws -> [ProposedProfileUpdate] {
        try fetchPendingRecords().compactMap(Self.update(from:))
    }

    func listAll() async throws -> [ProposedProfileUpdate] {
        let descriptor = FetchDescriptor<ProposedProfileUpdateRecord>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return try container.mainContext.fetch(descriptor).compactMap(Self.update(from:))
    }

    @discardableResult
    func enqueue(_ updates: [ProposedProfileUpdate]) async throws -> [ProposedProfileUpdate] {
        guard !updates.isEmpty else { return [] }
        let pending = try fetchPendingRecords()

        var enqueued: [ProposedProfileUpdate] = []
        for update in updates {
            guard !pending.contains(where: { $0.field == update.field.rawValue && $0.newValue == update.newValue }) else {
                continue
            }
            let record = ProposedProfileUpdateRecord(
                id: update.id,
                conversationId: update.conversationId,
                field: update.field.rawValue,
                newValue: update.newValue,
                previousValue: update.previousValue,
                isHighStakes: update.isHighStakes,
                sourceExcerpt: update.sourceExcerpt,
                createdAt: update.createdAt,
                status: update.status.rawValue
            )
            container.mainContext.insert(record)
            enqueued.append(update)
        }

        if !enqueued.isEmpty {
            try container.mainContext.save()
        }
        return enqueued
    }

    func resolve(id: UUID, status: ProposedProfileUpdate.Status) async throws {
        let target = id
        let predicate = #Predicate<ProposedProfileUpdateRecord> { $0.id == target }
        var descriptor = FetchDescriptor<ProposedProfileUpdateRecord>(predicate: predicate)
        descriptor.fetchLimit = 1
        guard let record = try container.mainContext.fetch(descriptor).first else { return }
        record.status = status.rawValue
        try container.mainContext.save()
    }

    // MARK: - Private

    private func fetchPendingRecords() throws -> [ProposedProfileUpdateRecord] {
        let target = ProposedProfileUpdate.Status.pending.rawValue
        let predicate = #Predicate<ProposedProfileUpdateRecord> { $0.status == target }
        let descriptor = FetchDescriptor<ProposedProfileUpdateRecord>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return try container.mainContext.fetch(descriptor)
    }

    private static func update(from record: ProposedProfileUpdateRecord) -> ProposedProfileUpdate? {
        guard let field = ProfileUpdateExtractor.FieldProposal.Field(rawValue: record.field),
              let status = ProposedProfileUpdate.Status(rawValue: record.status) else { return nil }
        return ProposedProfileUpdate(
            id: record.id,
            conversationId: record.conversationId,
            field: field,
            newValue: record.newValue,
            previousValue: record.previousValue,
            isHighStakes: record.isHighStakes,
            sourceExcerpt: record.sourceExcerpt,
            createdAt: record.createdAt,
            status: status
        )
    }
}
