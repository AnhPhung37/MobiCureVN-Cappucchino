import XCTest
@testable import MobiCureVN

/// Tests for `HomeViewModel` — the summarising layer behind the real-data Home screen (#54).
///
/// Home shows a glance of each field and hands the full list to Profile, so the truncation,
/// ordering and filtering rules live in the view model where they can be tested rather than
/// in the view. A new build passes if:
///   - summaries cap at the documented limit and preserve the stored order (no severity
///     ranking — warning signs must never be reordered by the app)
///   - remembered facts show only what the patient actually accepted, newest first
///   - counts reported to the UI are the *uncapped* totals, so "3 of 7" cannot lie
///   - an empty store yields empty collections, never placeholder or fabricated content
///   - one failing repository degrades that card only, instead of blanking the screen
@MainActor
final class HomeViewModelTests: XCTestCase {

    // MARK: - Test doubles

    /// Returns a caller-supplied profile, or throws — lets a test drive the failure path
    /// without reaching for a real store.
    private struct StubProfileRepository: ProfileRepository {
        var profile: PatientProfile?
        var error: Error?

        func fetchProfile() async throws -> PatientProfile {
            if let error { throw error }
            guard let profile else { throw StubError.noProfile }
            return profile
        }

        func save(_ profile: PatientProfile) async throws {}
    }

    private enum StubError: Error { case noProfile, unreachable }

    private let patientID = UUID()

    private func makeProfile(
        careNotes: [String] = [],
        warningSigns: [String] = []
    ) -> PatientProfile {
        PatientProfile(
            id: patientID,
            name: "Nguyen Van A",
            age: 52,
            gender: "Male",
            diagnosis: "Colorectal cancer",
            procedure: "Sigmoid colectomy",
            recoveryStage: "Early recovery",
            reportSummary: "Stable recovery after surgery.",
            careNotes: careNotes,
            warningSigns: warningSigns,
            sourceName: "Discharge summary",
            lastUpdated: Date(timeIntervalSince1970: 1_750_000_000)
        )
    }

    private func makeUpdate(
        field: ProfileUpdateExtractor.FieldProposal.Field,
        value: String,
        status: ProposedProfileUpdate.Status,
        createdAt: Date
    ) -> ProposedProfileUpdate {
        ProposedProfileUpdate(
            conversationId: UUID(),
            field: field,
            newValue: value,
            previousValue: nil,
            isHighStakes: false,
            sourceExcerpt: "Toi bi di ung \(value).",
            createdAt: createdAt,
            status: status
        )
    }

    private func makeWoundEntry(capturedAt: Date) -> WoundLogEntry {
        WoundLogEntry(
            patientID: patientID,
            capturedAt: capturedAt,
            imageReference: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).jpg"),
            stomaColor: "Hong",
            stomaSizeChange: WoundFindingsParser.notReported,
            surroundingSkin: "Binh thuong",
            outputAppearance: WoundFindingsParser.notReported,
            bagSeal: WoundFindingsParser.notReported,
            swellingOrProtrusion: WoundFindingsParser.notReported,
            otherObservations: WoundFindingsParser.notReported,
            rawDescription: "raw",
            modelUsed: "test"
        )
    }

    private func makeViewModel(
        profileRepository: ProfileRepository,
        updates: [ProposedProfileUpdate] = [],
        woundEntries: [WoundLogEntry] = []
    ) async -> HomeViewModel {
        let updateRepository = InMemoryProfileUpdateRepository()
        // enqueue() only accepts pending proposals through its dedupe guard, so resolved
        // statuses are applied afterwards the same way the confirmation UI does it.
        for update in updates {
            var pending = update
            pending.status = .pending
            try? await updateRepository.enqueue([pending])
            if update.status != .pending {
                try? await updateRepository.resolve(id: update.id, status: update.status)
            }
        }

        let woundRepository = InMemoryWoundLogRepository()
        for entry in woundEntries {
            try? await woundRepository.append(entry)
        }

        return HomeViewModel(
            profileRepository: profileRepository,
            profileUpdateRepository: updateRepository,
            woundLogRepository: woundRepository,
            patientID: patientID
        )
    }

    // MARK: - Care notes and warning signs

    func testSummariesCapAtLimitAndPreserveStoredOrder() async {
        let notes = ["Note one", "Note two", "Note three", "Note four", "Note five"]
        let signs = ["Fever", "Pus at the wound", "Worsening pain", "Cannot keep fluids down"]
        let profile = makeProfile(careNotes: notes, warningSigns: signs)
        let viewModel = await makeViewModel(profileRepository: StubProfileRepository(profile: profile))

        await viewModel.load()

        XCTAssertEqual(viewModel.careNotesSummary, Array(notes.prefix(3)))
        XCTAssertEqual(viewModel.warningSignsSummary, Array(signs.prefix(3)))
        XCTAssertEqual(viewModel.careNotesTotalCount, 5)
        XCTAssertEqual(viewModel.warningSignsTotalCount, 4)
        XCTAssertTrue(viewModel.hasMoreCareNotes)
        XCTAssertTrue(viewModel.hasMoreWarningSigns)
    }

    func testSummariesReturnEverythingWhenBelowLimit() async {
        let notes = ["Only note"]
        let signs = ["Fever", "Pus at the wound"]
        let profile = makeProfile(careNotes: notes, warningSigns: signs)
        let viewModel = await makeViewModel(profileRepository: StubProfileRepository(profile: profile))

        await viewModel.load()

        XCTAssertEqual(viewModel.careNotesSummary, notes)
        XCTAssertEqual(viewModel.warningSignsSummary, signs)
        XCTAssertFalse(viewModel.hasMoreCareNotes, "One note is not 'more' than the cap of three")
        XCTAssertFalse(viewModel.hasMoreWarningSigns)
    }

    // MARK: - Remembered facts

    func testRememberedFactsExcludePendingAndDismissedProposals() async {
        let base = Date(timeIntervalSince1970: 1_750_000_000)
        let updates = [
            makeUpdate(field: .allergyAdd, value: "Penicillin", status: .accepted, createdAt: base),
            makeUpdate(field: .medicationAdd, value: "Ibuprofen", status: .pending, createdAt: base.addingTimeInterval(10)),
            makeUpdate(field: .conditionAdd, value: "Asthma", status: .dismissed, createdAt: base.addingTimeInterval(20))
        ]
        let viewModel = await makeViewModel(
            profileRepository: StubProfileRepository(profile: makeProfile()),
            updates: updates
        )

        await viewModel.load()

        XCTAssertEqual(viewModel.rememberedFacts.map(\.value), ["Penicillin"])
        XCTAssertEqual(viewModel.rememberedFactsTotalCount, 1)
    }

    func testRememberedFactsAreNewestFirstAndCapped() async {
        let base = Date(timeIntervalSince1970: 1_750_000_000)
        let updates = (0..<5).map { index in
            makeUpdate(
                field: .allergyAdd,
                value: "Allergy \(index)",
                status: .accepted,
                createdAt: base.addingTimeInterval(TimeInterval(index * 60))
            )
        }
        let viewModel = await makeViewModel(
            profileRepository: StubProfileRepository(profile: makeProfile()),
            updates: updates
        )

        await viewModel.load()

        XCTAssertEqual(viewModel.rememberedFacts.map(\.value), ["Allergy 4", "Allergy 3", "Allergy 2"])
        XCTAssertEqual(viewModel.rememberedFactsTotalCount, 5, "The badge reports every accepted fact, not the capped three")
        XCTAssertTrue(viewModel.hasMoreRememberedFacts)
        XCTAssertEqual(viewModel.rememberedFacts.first?.label, ProfileUpdateExtractor.FieldProposal.Field.allergyAdd.displayLabel)
    }

    // MARK: - Wound photos

    func testRecentWoundEntriesAreNewestFirstAndCappedWhileCountStaysTotal() async {
        let base = Date(timeIntervalSince1970: 1_750_000_000)
        let entries = (0..<6).map { makeWoundEntry(capturedAt: base.addingTimeInterval(TimeInterval($0 * 3600))) }
        let viewModel = await makeViewModel(
            profileRepository: StubProfileRepository(profile: makeProfile()),
            woundEntries: entries
        )

        await viewModel.load()

        XCTAssertEqual(viewModel.recentWoundEntries.count, 4)
        XCTAssertEqual(
            viewModel.recentWoundEntries.map(\.capturedAt),
            entries.suffix(4).reversed().map(\.capturedAt)
        )
        XCTAssertEqual(viewModel.woundEntriesTotalCount, 6)
        XCTAssertTrue(viewModel.hasMoreWoundPhotos)
        XCTAssertEqual(viewModel.allWoundEntries.count, 6, "The gallery needs every entry, not the capped four")
        XCTAssertEqual(viewModel.allWoundEntries.first?.capturedAt, entries.last?.capturedAt)
    }

    // MARK: - Empty states

    func testEmptyStoresYieldEmptyCollectionsRatherThanPlaceholders() async {
        let viewModel = await makeViewModel(profileRepository: StubProfileRepository(profile: makeProfile()))

        await viewModel.load()

        XCTAssertTrue(viewModel.careNotesSummary.isEmpty)
        XCTAssertTrue(viewModel.warningSignsSummary.isEmpty)
        XCTAssertTrue(viewModel.rememberedFacts.isEmpty)
        XCTAssertTrue(viewModel.recentWoundEntries.isEmpty)
        XCTAssertFalse(viewModel.hasMoreCareNotes)
        XCTAssertFalse(viewModel.hasMoreRememberedFacts)
        XCTAssertFalse(viewModel.hasMoreWoundPhotos)
        XCTAssertFalse(viewModel.isLoading, "load() must clear its loading flag even with nothing to show")
        XCTAssertNil(viewModel.errorMessage)
    }

    // MARK: - Partial failure

    func testFailingProfileFetchStillLoadsFactsAndPhotos() async {
        let base = Date(timeIntervalSince1970: 1_750_000_000)
        let viewModel = await makeViewModel(
            profileRepository: StubProfileRepository(error: StubError.unreachable),
            updates: [makeUpdate(field: .allergyAdd, value: "Penicillin", status: .accepted, createdAt: base)],
            woundEntries: [makeWoundEntry(capturedAt: base)]
        )

        await viewModel.load()

        XCTAssertNil(viewModel.profile)
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.rememberedFacts.count, 1, "A profile failure must not blank the memory card")
        XCTAssertEqual(viewModel.recentWoundEntries.count, 1, "A profile failure must not blank the photo card")
        XCTAssertFalse(viewModel.isLoading)
    }
}
