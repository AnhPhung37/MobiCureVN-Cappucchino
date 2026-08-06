import Foundation

actor InMemoryProfileUpdateRepository: ProfileUpdateRepository {
    private var updates: [ProposedProfileUpdate] = []

    func listPending() async throws -> [ProposedProfileUpdate] {
        updates
            .filter { $0.status == .pending }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func listAll() async throws -> [ProposedProfileUpdate] {
        updates.sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    func enqueue(_ newUpdates: [ProposedProfileUpdate]) async throws -> [ProposedProfileUpdate] {
        var enqueued: [ProposedProfileUpdate] = []
        for update in newUpdates {
            guard !updates.contains(where: { $0.status == .pending && $0.field == update.field && $0.newValue == update.newValue }) else {
                continue
            }
            updates.append(update)
            enqueued.append(update)
        }
        return enqueued
    }

    func resolve(id: UUID, status: ProposedProfileUpdate.Status) async throws {
        guard let index = updates.firstIndex(where: { $0.id == id }) else { return }
        updates[index].status = status
    }
}
