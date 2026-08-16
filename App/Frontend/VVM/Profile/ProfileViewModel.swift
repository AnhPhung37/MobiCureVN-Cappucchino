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

        // Wound photos, session facts, and update history are independent of the profile
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

        let allUpdates = (try? await profileUpdateRepository.listAll()) ?? []
        highStakesHistory = allUpdates
            .filter { $0.isHighStakes && $0.status != .pending }
            .sorted { $0.createdAt > $1.createdAt }

        isLoading = false
    }

    // MARK: - Direct Patient Edits

    /// Write the patient's hand-entered identity fields (photo/name/age/gender) straight
    /// through. Unlike an AI proposal this needs no confirmation step — the patient typed it
    /// themselves, and it cannot touch a clinical field (see `PatientProfile.Edits`).
    @MainActor
    func saveEdits(_ edits: PatientProfile.Edits) async {
        guard let currentProfile = profile else { return }
        let updated = currentProfile.applying(edits)
        do {
            try await repository.save(updated)
            profile = updated
        } catch {
            errorMessage = "Không thể lưu thay đổi hồ sơ. Vui lòng thử lại.".localized(for: .current)
        }
    }

    /// "wound_location" → "Wound location". Mirrors `SessionFactStore.label(for:)`, duplicated
    /// here because that helper is private to the store.
    private static func humanize(_ key: String) -> String {
        let spaced = key.replacingOccurrences(of: "_", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }
}
