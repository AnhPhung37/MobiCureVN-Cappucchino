import Foundation
import Observation

/// Backs the Home dashboard (#54), which replaced a static mockup whose greeting, streak and
/// appointment were all invented. Everything exposed here comes from a repository or is empty —
/// there is no placeholder path, because fabricated content on a recovery screen is worse than
/// an empty card.
///
/// Home *summarises*; `ProfileView` owns the full lists and all editing. The truncation and
/// ordering rules therefore live here rather than in the view, so they can be tested.
@Observable
final class HomeViewModel {

    /// One durable thing the assistant knows, derived from an accepted `ProposedProfileUpdate`.
    ///
    /// Deliberately *not* backed by `SessionFactStore`: that store is an in-memory actor keyed
    /// by conversation, so a root-screen card reading from it would be blank on every cold
    /// launch and whenever no chat is open. Accepted proposals are SwiftData-backed and are
    /// what the patient actually confirmed the assistant should carry between sessions.
    struct RememberedFact: Identifiable, Equatable {
        let id: UUID
        let label: String
        let value: String
        let recordedAt: Date
        /// The chat message that prompted it, so the patient can see why it is remembered.
        let sourceExcerpt: String
    }

    /// How many items a summary card shows before deferring to "see all". Three keeps every
    /// card readable at extraLarge text size without the screen turning into a wall of text.
    static let summaryItemLimit = 3
    /// Wound photos are thumbnails in a single row, so four fits where three text lines do.
    static let recentWoundPhotoLimit = 4

    private let profileRepository: ProfileRepository
    private let profileUpdateRepository: ProfileUpdateRepository
    private let woundLogRepository: WoundLogRepository
    private let patientID: UUID

    init(
        profileRepository: ProfileRepository = AppConfig.profileRepository,
        profileUpdateRepository: ProfileUpdateRepository = AppConfig.profileUpdateStore,
        woundLogRepository: WoundLogRepository = AppConfig.woundLogRepository,
        patientID: UUID = AppConfig.localPatientID
    ) {
        self.profileRepository = profileRepository
        self.profileUpdateRepository = profileUpdateRepository
        self.woundLogRepository = woundLogRepository
        self.patientID = patientID
    }

    var profile: PatientProfile?
    /// Every wound entry, newest first — the gallery's source. Home's card shows a prefix.
    var allWoundEntries: [WoundLogEntry] = []
    /// Every accepted fact, newest first. Home's card shows a prefix.
    var allRememberedFacts: [RememberedFact] = []
    var isLoading = false
    var errorMessage: String?

    // MARK: - Summaries
    //
    // Each pairs a capped list with the *uncapped* total, so a card can say "3 of 7" without
    // the count being derived from the truncated array and quietly under-reporting.

    /// Care notes in the order the clinician's report stored them. Never re-sorted.
    var careNotesSummary: [String] {
        Array((profile?.careNotes ?? []).prefix(Self.summaryItemLimit))
    }
    var careNotesTotalCount: Int { profile?.careNotes.count ?? 0 }
    var hasMoreCareNotes: Bool { careNotesTotalCount > careNotesSummary.count }

    /// Warning signs in stored order. Deliberately not ranked by severity: the app is an
    /// assistant, not a triage tool, and implying an ordering would be a clinical judgement.
    var warningSignsSummary: [String] {
        Array((profile?.warningSigns ?? []).prefix(Self.summaryItemLimit))
    }
    var warningSignsTotalCount: Int { profile?.warningSigns.count ?? 0 }
    var hasMoreWarningSigns: Bool { warningSignsTotalCount > warningSignsSummary.count }

    var rememberedFacts: [RememberedFact] {
        Array(allRememberedFacts.prefix(Self.summaryItemLimit))
    }
    var rememberedFactsTotalCount: Int { allRememberedFacts.count }
    var hasMoreRememberedFacts: Bool { rememberedFactsTotalCount > rememberedFacts.count }

    var recentWoundEntries: [WoundLogEntry] {
        Array(allWoundEntries.prefix(Self.recentWoundPhotoLimit))
    }
    var woundEntriesTotalCount: Int { allWoundEntries.count }
    var hasMoreWoundPhotos: Bool { woundEntriesTotalCount > recentWoundEntries.count }

    // MARK: - Loading

    /// Mirrors `ProfileViewModel.load()`'s error policy: only the profile fetch can surface an
    /// error, because it is the one failure the patient can act on (re-open, re-import). The
    /// other two are best-effort so a single failing repository degrades its own card instead
    /// of blanking the screen.
    @MainActor
    func load() async {
        isLoading = true
        errorMessage = nil

        do {
            profile = try await profileRepository.fetchProfile()
        } catch {
            profile = nil
            errorMessage = String(describing: error)
        }

        allWoundEntries = ((try? await woundLogRepository.loadEntries(patientID: patientID)) ?? [])
            .sorted { $0.capturedAt > $1.capturedAt }

        let updates = (try? await profileUpdateRepository.listAll()) ?? []
        allRememberedFacts = updates
            .filter { $0.status == .accepted }
            .sorted { $0.createdAt > $1.createdAt }
            .map {
                RememberedFact(
                    id: $0.id,
                    label: $0.field.displayLabel,
                    value: $0.newValue,
                    recordedAt: $0.createdAt,
                    sourceExcerpt: $0.sourceExcerpt
                )
            }

        isLoading = false
    }
}
