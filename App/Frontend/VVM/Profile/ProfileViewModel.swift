import Foundation
import Observation

@Observable
final class ProfileViewModel {
    private let repository: ProfileRepository
    private let woundLogRepository: WoundLogRepository
    private let factStore: SessionFactStore
    private let profileUpdateRepository: ProfileUpdateRepository
    private let patientID: UUID

    /// The conversation whose remembered facts are shown as the "system prompt". Supplied by the
    /// chat surface so Profile reflects the active conversation; nil means no live conversation
    /// (e.g. previews), in which case the facts section is simply empty.
    private let conversationId: UUID?

    init(
        repository: ProfileRepository,
        woundLogRepository: WoundLogRepository = AppConfig.woundLogRepository,
        factStore: SessionFactStore = AppConfig.sessionFactStore,
        profileUpdateRepository: ProfileUpdateRepository = AppConfig.profileUpdateStore,
        patientID: UUID = AppConfig.localPatientID,
        conversationId: UUID? = nil
    ) {
        self.repository = repository
        self.woundLogRepository = woundLogRepository
        self.factStore = factStore
        self.profileUpdateRepository = profileUpdateRepository
        self.patientID = patientID
        self.conversationId = conversationId
    }

    var profile: PatientProfile?
    var woundEntries: [WoundLogEntry] = []
    /// Facts the user has stated this conversation, as (label, value) pairs — the same content
    /// injected into the live system prompt. Empty when nothing has been remembered yet.
    var rememberedFacts: [(label: String, value: String)] = []
    /// AI-proposed profile updates awaiting patient confirmation, from any conversation — not
    /// scoped to `conversationId`, so a proposal surfaced in one chat and ignored still shows
    /// up here (the durable fallback surface — see `ProfileUpdateRepository`).
    var pendingUpdates: [ProposedProfileUpdate] = []
    /// Resolved (accepted or dismissed) high-stakes proposals, newest first — the clinical
    /// change audit trail, so a bad edit to diagnosis/procedure/recovery stage can be spotted
    /// after the fact even though nothing after Accept requires a clinician's sign-off.
    var highStakesHistory: [ProposedProfileUpdate] = []
    var isLoading: Bool = false
    var errorMessage: String?

    /// True when the session facts are empty — lets the view show a friendly explanation rather
    /// than a blank card.
    var hasRememberedFacts: Bool { !rememberedFacts.isEmpty }

    @MainActor
    func load() async {
        isLoading = true
        errorMessage = nil
        do {
            profile = try await repository.fetchProfile()
        } catch {
            errorMessage = String(describing: error)
        }

        // Wound photos, session facts, and pending updates are independent of the profile
        // fetch; failures here shouldn't blank the whole screen, so they're loaded best-effort.
        // Newest first — the log is browsed as a recent-history feed.
        woundEntries = ((try? await woundLogRepository.loadEntries(patientID: patientID)) ?? [])
            .sorted { $0.capturedAt > $1.capturedAt }

        if let conversationId {
            let facts = await factStore.facts(for: conversationId)
            rememberedFacts = facts.map { (label: Self.humanize($0.key), value: $0.value) }
        } else {
            rememberedFacts = []
        }

        pendingUpdates = (try? await profileUpdateRepository.listPending()) ?? []

        let allUpdates = (try? await profileUpdateRepository.listAll()) ?? []
        highStakesHistory = allUpdates
            .filter { $0.isHighStakes && $0.status != .pending }
            .sorted { $0.createdAt > $1.createdAt }

        isLoading = false
    }

    // MARK: - Profile Update Confirmation

    /// Patient confirmed a proposed profile change: writes it through to the persisted
    /// profile, resolves the pending record, and refreshes local state.
    @MainActor
    func accept(_ update: ProposedProfileUpdate) async {
        guard let currentProfile = profile else { return }
        do {
            let updatedProfile = currentProfile.applying(update)
            try await repository.save(updatedProfile)
            try await profileUpdateRepository.resolve(id: update.id, status: .accepted)
            profile = updatedProfile
            pendingUpdates.removeAll { $0.id == update.id }
            if update.isHighStakes {
                var resolved = update
                resolved.status = .accepted
                highStakesHistory.insert(resolved, at: 0)
            }
        } catch {
            errorMessage = "Không thể lưu thay đổi hồ sơ. Vui lòng thử lại.".localized(for: .current)
        }
    }

    /// Patient declined a proposed profile change — nothing is written to the profile.
    @MainActor
    func dismiss(_ update: ProposedProfileUpdate) async {
        try? await profileUpdateRepository.resolve(id: update.id, status: .dismissed)
        pendingUpdates.removeAll { $0.id == update.id }
        if update.isHighStakes {
            var resolved = update
            resolved.status = .dismissed
            highStakesHistory.insert(resolved, at: 0)
        }
    }

    /// "wound_location" → "Wound location". Mirrors `SessionFactStore.label(for:)`, duplicated
    /// here because that helper is private to the store.
    private static func humanize(_ key: String) -> String {
        let spaced = key.replacingOccurrences(of: "_", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }
}
