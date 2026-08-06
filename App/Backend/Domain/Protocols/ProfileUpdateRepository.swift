import Foundation

/// Stages AI-proposed profile updates awaiting patient confirmation. Internally scoped to the
/// one profile this device has (see `ProposedProfileUpdate` and `ProfileRepository`) — no id
/// parameter needed on any method.
protocol ProfileUpdateRepository {
    func listPending() async throws -> [ProposedProfileUpdate]
    /// Every proposal regardless of status, newest first — powers the high-stakes-field audit
    /// trail in the Profile tab (a resolved proposal keeps its `previousValue`/`sourceExcerpt`/
    /// `createdAt`, so "what changed and when" survives past the confirmation moment).
    func listAll() async throws -> [ProposedProfileUpdate]
    /// Persists `updates`, skipping any that duplicate an already-pending proposal (same
    /// field + value) so a fact repeated across turns before the patient acts on it doesn't
    /// stack duplicate cards. Returns the subset that was actually enqueued.
    @discardableResult
    func enqueue(_ updates: [ProposedProfileUpdate]) async throws -> [ProposedProfileUpdate]
    func resolve(id: UUID, status: ProposedProfileUpdate.Status) async throws
}
