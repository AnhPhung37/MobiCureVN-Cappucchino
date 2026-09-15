# Home Screen — Real Data Dashboard (#54)

Date: 2026-09-15
Ticket: #54 — Home screen is a static mockup with fake data and dead buttons

## Problem

`App/Frontend/VVM/Onboarding/HomeContentView.swift` is a 350-line visual mockup. Every
value in it is invented: the greeting `"Chào Nam,"`, the streak `"256 days STRONG"`, the
appointment `"Dr. Schmitz" / "11:30 - 12:00"`. Two buttons — the hamburger menu and
"Xem phân tích" — have empty actions. Section headers are English on an otherwise
Vietnamese screen.

It is also unreachable. `HomeView.swift:6` renders `ChatWorkspaceView()`; nothing
references `HomeContentView` except its own `#Preview`. The medication feature it pulls
in (`Medication.swift`, `MedicationListView.swift`, `DayDetailView.swift`,
`AddMedicationView.swift`) is unreachable for the same reason — but unlike the mockup it
is functional code: `MedicationStore` persists to `UserDefaults`, schedules local
`UNUserNotificationCenter` reminders, tracks adherence events, and is covered by
`MedicationStoreTests`. It starts empty rather than with sample data.

Fabricated clinical-adjacent content on a patient-safety surface is worse than no
content. The screen must show real data or an honest empty state.

## Scope

Home becomes the app's root screen. Chat becomes a destination reached from it. Home
surfaces five fields, all backed by data that already exists on device:

| Field | Backing data | Already exists at |
|---|---|---|
| Care notes | `PatientProfile.careNotes` | `ProfileRepository` |
| Warning signs | `PatientProfile.warningSigns` | `ProfileRepository` |
| What the assistant remembers about you | accepted `ProposedProfileUpdate` records | `ProfileUpdateRepository` |
| Uploaded wound photos | `WoundLogEntry` | `WoundLogRepository` |
| Data source | `PatientProfile.sourceName` / `.lastUpdated` | `ProfileRepository` |

All three repositories are already protocol-backed and already resolved through
`AppConfig`. **This change requires no backend work**: no new `@Model`, no new
repository, no `ModelContainer` migration, no change to the chat, RAG, guardrail or
emergency-detection paths.

### Division of responsibility: Home vs. Profile

`ProfileView` already renders all five fields in full, plus editing. To avoid rendering
the same content twice with two sources of truth:

- **Home summarises.** Each card shows at most the top 3 items (top 4 for wound photo
  thumbnails) and a "Xem tất cả" affordance.
- **Profile owns the full list and all editing.** `ProfileView` is unchanged in content;
  it gains only the ability to open scrolled to a requested section.

The one exception is wound photos, which get a new dedicated full-screen gallery
(`WoundGalleryView`) rather than tapping through to Profile — a photo grid needs more
room than a Profile section gives it.

### Out of scope

- No new wound-photo capture path. Photos continue to originate only from attaching an
  image in chat, where `WoundAnalysisService` and the guardrail path already run. Adding
  a second analysis entry point would create a second safety surface to review, which
  this ticket does not cover.
- No calendar, medication tracking, appointment or streak feature. See Deletions.
- No change to `ProfileView`'s existing cards, `ProfileViewModel`, or any backend service.

## Navigation

```
AppRootView
└── HomeView                        keeps .translationTask setup (global TranslationService)
    └── NavigationStack
        └── HomeDashboardView       new
            ├── toolbar ▸ person.crop.circle → ProfileView (sheet)
            ├── greetingCard        profile.name, recoveryStage, [Trò chuyện] → push chat
            ├── careNotesCard       top 3 → ProfileView §careNotes
            ├── warningSignsCard    top 3 → ProfileView §warningSigns
            ├── rememberedCard      top 3 → ProfileView §remembered
            ├── woundPhotosCard     latest 4 → WoundGalleryView
            └── dataSourceCard      sourceName, lastUpdated, on-device notice
```

`HomeView` keeps its two `.translationTask` modifiers and the
`checkLanguageAvailability()` task. These configure the process-wide
`AppConfig.translationService` and must remain above chat in the hierarchy.

`ChatWorkspaceView` has no `NavigationStack` of its own — its body is a `GeometryReader`
wrapping a `ZStack` with a custom sidebar — so it can be pushed. It will gain a system
back button above its own hamburger control. If that reads badly at compact width during
implementation, the fallback is a `fullScreenCover` with an explicit "Trang chủ" control
added to the chat sidebar. The decision is made by looking at the built screen at iPhone
width, not in advance.

`ProfileView` continues to be presented as a sheet, as it is today from the chat sidebar.
Both entry points remain.

## New files

All under `App/Frontend/VVM/Home/`.

### `HomeViewModel.swift`

`@Observable final class`, mirroring `ProfileViewModel`'s shape and its
constructor-injection style.

Dependencies, all defaulted to `AppConfig`:

```swift
init(
    profileRepository: ProfileRepository = AppConfig.profileRepository,
    profileUpdateRepository: ProfileUpdateRepository = AppConfig.profileUpdateStore,
    woundLogRepository: WoundLogRepository = AppConfig.woundLogRepository,
    patientID: UUID = AppConfig.localPatientID
)
```

Published state:

```swift
var profile: PatientProfile?
var rememberedFacts: [RememberedFact]   // accepted updates, newest first
var recentWoundEntries: [WoundLogEntry] // newest first, capped at 4
var totalWoundEntryCount: Int           // full count, for the card badge
var isLoading: Bool
var errorMessage: String?
```

`RememberedFact` is a small view-facing struct built in the view model from a
`ProposedProfileUpdate`: `label` (from `field.displayLabel`), `value` (`newValue`),
`recordedAt` (`createdAt`), `sourceExcerpt`.

`load()` mirrors `ProfileViewModel.load()`'s error policy exactly: a profile fetch
failure sets `errorMessage`; the other two loads are best-effort (`try?`) so one failing
repository cannot blank the whole screen.

Summary truncation lives in the view model, not the view, so it is testable:

- `careNotesSummary` / `warningSignsSummary` — first 3 of the profile arrays
- `rememberedFacts` — accepted-only, sorted by `createdAt` descending, first 3
- `recentWoundEntries` — sorted by `capturedAt` descending, first 4

`totalWoundEntryCount` is the count before capping, so the card can show "4 of 12".

### `HomeSummaryCard.swift`

Shared card chrome: icon, title, optional count badge, content slot, optional
"Xem tất cả" footer button. All five cards use it so spacing, corner radius and
background stay identical. Matches `ProfileView`'s existing card treatment
(18pt continuous corner radius, `Color(.secondarySystemBackground)`).

### `HomeDashboardView.swift`

The dashboard. Composes the five cards plus the greeting card inside a `ScrollView`.
Holds the `ProfileView` sheet state and the navigation destination for chat and gallery.

### `WoundGalleryView.swift`

A `LazyVGrid` of every `WoundLogEntry`, newest first, thumbnails loaded the same way
`ProfileView.woundThumbnail(_:)` does it — `UIImage(contentsOfFile:)` with a placeholder
fallback for an entry whose file is gone. Tapping a thumbnail opens a detail sheet
showing the full image, capture date, and the parsed findings (`stomaColor`,
`stomaSizeChange`, `surroundingSkin`, `outputAppearance`, `bagSeal`,
`swellingOrProtrusion`, `otherObservations`), hiding any field equal to
`WoundFindingsParser.notReported` — the same suppression `ProfileView.woundDetail`
already applies.

## Change to `ProfileView`

One additive change, to make Home's "Xem tất cả" land in the right place:

```swift
enum ProfileSection: String, Hashable { case careNotes, warningSigns, remembered }

init(viewModel: ProfileViewModel = …, scrollTo section: ProfileSection? = nil)
```

The body wraps its existing `VStack` in a `ScrollViewReader`, tags the three relevant
cards with `.id(ProfileSection.…)`, and on appear scrolls to `section` when non-nil.
Default `nil` preserves today's behaviour exactly, so the existing presentation from the
chat sidebar is unaffected. No existing card's content changes.

## "What the assistant remembers about you"

This card is backed by **accepted `ProposedProfileUpdate` records**, not by
`SessionFactStore`.

`SessionFactStore` is an in-memory actor keyed by conversation
(`SessionFactStore.swift:41`). It has no persistence and no cross-conversation view. A
root-screen card backed by it would be empty on every cold launch and empty whenever no
conversation is open — reintroducing exactly the dead-card problem this ticket removes.

`ProfileUpdateRepository.listAll()` is SwiftData-backed via
`SwiftDataProfileUpdateRepository`, survives relaunch, and a resolved proposal retains
its `previousValue`, `sourceExcerpt` and `createdAt`. Filtering to `.accepted` gives the
durable set of things the patient confirmed the assistant should know — which is what
"remembers about you" means to a patient.

`ProfileView`'s existing per-conversation facts card is left exactly as it is. The two
are different things and are labelled differently: Home says "Trợ lý ghi nhớ về bạn"
(durable), Profile's existing card keeps its current conversation-scoped wording.

Empty state: a sentence saying the assistant has not recorded anything yet and that it
picks up details from chat when the patient confirms them. Not a blank card.

## Patient safety

- **No ranking or triage.** The warning signs card lists profile entries verbatim in
  stored order, truncated to the first 3. It does not sort by severity, score, or
  imply which signs matter more. Truncation is presented as truncation, with the full
  list one tap away.
- **Cautionary, not alarming.** Warning signs use the existing warning treatment
  (`exclamationmark.triangle.fill`, orange) already used in `ProfileView`. No red alert
  banners, no persistent badge, nothing that reads as an active clinical alarm.
- **Wound findings stay provisional.** The gallery repeats the assistant's
  non-diagnostic framing and preserves the existing `flaggedForReview` badge
  ("Cần theo dõi"). Findings are presented as observations to show a clinician, never as
  conclusions.
- **No clinical authority.** Nothing on Home implies the app has assessed the patient.
  The greeting is a greeting; it carries no status judgement, no recovery score, no
  streak.
- **No fabrication.** Every card renders real stored data or an honest empty state. No
  placeholder names, dates, counts, or sample entries ship in this screen.
- **Nothing leaves the device.** No network calls, no analytics. The data source card
  states the source name, its last-updated date, and that data stays on device.

## Deletions

| File | Lines | Reason |
|---|---|---|
| `App/Frontend/VVM/Onboarding/HomeContentView.swift` | 350 | The mockup this ticket removes |
| `App/Frontend/VVM/Onboarding/Medication.swift` | 270 | Medication feature — out of scope, unreachable |
| `App/Frontend/VVM/Onboarding/MedicationListView.swift` | 76 | Medication feature |
| `App/Frontend/VVM/Onboarding/DayDetailView.swift` | 78 | Medication feature |
| `App/Frontend/VVM/Onboarding/AddMedicationView.swift` | 68 | Medication feature |
| `MobiCureVNTests/MedicationStoreTests.swift` | — | Covers deleted code |

The medication files are deleted knowing they are functional rather than fake: they have
never been reachable by a patient, the feature is outside this ticket's five fields, and
git history keeps them recoverable if the team decides to build the feature properly
later. This was confirmed explicitly rather than assumed.

`App/` is a `PBXFileSystemSynchronizedRootGroup`, so removal is by deleting the files.
`project.pbxproj` must not be edited. `MobiCureVNTests/` is a conventional group; if
removing its test file requires a project change, that is done in Xcode, not by hand.

After deletion, `HomeView.swift` is rewritten to host the dashboard. The `Onboarding/`
folder then holds only `HomeView.swift`, which is moved to `VVM/Home/` so the folder name
matches its contents; the onboarding flow itself lives in `VVM/Welcome/` and is untouched.

`Docs/FE/inconsistenciesRefactor.md` and `Docs/FE/Frontend-Performance-Notes.md` both
cite `HomeContentView` line numbers. Their rows for the deleted file are removed so the
docs do not point at files that no longer exist.

## Conventions

- **Typography:** `.appFont(size:weight:design:)` on every `Text`. A raw
  `.font(.system(size:))` would silently ignore the patient's Text Size setting. Note
  that `ProfileView` uses `.font(.headline)` in several card titles — new Home cards use
  `.appFont` with an explicit size instead, so they scale with `\.textSizeScale`.
- **Localization:** every user-facing string is added to `App/Localizable.xcstrings`
  keyed by its Vietnamese source text, with an `en` translation. Inside SwiftUI `Text`,
  literals resolve through the environment locale. `HomeViewModel` and any formatter use
  `"…".localized(for: appLanguage)` with an `@AppStorage(AppLanguage.storageKey)` read.
- **Layer boundary:** `HomeViewModel` lives in `App/Frontend/VVM/Home/` beside its view
  and depends only on protocols from `App/Backend/Domain/Protocols/`. No view reaches a
  service directly. No SwiftUI import is added anywhere under `App/Backend`.
- **Colour:** semantic system colours and `Color(.label)` / `Color(.secondaryLabel)`, as
  the rest of the app does. No new colorset is added to `Assets.xcassets` — four dead
  ones already exist there.
- **Spacing:** 4-point grid, matching the 12 / 16 / 20 / 24 clustering in `ProfileView`.
- **Appearance:** the app forces light or dark rather than following the system, so both
  schemes are checked deliberately. No gradient with white text that only works in one.

## Accessibility

- Every icon-only button — the toolbar profile button, the gallery close button, each
  thumbnail — gets an `accessibilityLabel`.
- The `flaggedForReview` state is conveyed by icon and text ("Cần theo dõi"), not by
  colour alone.
- Card headers are marked `.accessibilityAddTraits(.isHeader)` so VoiceOver rotor
  navigation works.
- Wound thumbnails in the grid get a label naming the capture date, so the grid is
  navigable without sight of the images.
- The screen is checked at `extraLarge` text size (1.3×) for clipping, and at both
  languages for truncation — Vietnamese strings run longer than their English
  counterparts.

## Testing

New `MobiCureVNTests/HomeViewModelTests.swift`, using the existing
`MockProfileRepository`, `InMemoryProfileUpdateRepository` and
`InMemoryWoundLogRepository`:

1. `careNotesSummary` and `warningSignsSummary` return at most 3 items, in stored order.
2. Fewer than 3 stored items returns all of them, unpadded.
3. `rememberedFacts` excludes `.pending` and `.dismissed` proposals.
4. `rememberedFacts` is ordered newest-first by `createdAt` and capped at 3.
5. `recentWoundEntries` is ordered newest-first by `capturedAt` and capped at 4, while
   `totalWoundEntryCount` reports the uncapped total.
6. Each empty state: no profile, no accepted updates, no wound entries — the view model
   exposes empty collections rather than throwing or leaving `isLoading` true.
7. A failing profile fetch sets `errorMessage` and still loads wound entries and
   remembered facts.

Existing tests are untouched. The guardrail, emergency-detection and language-validation
suites are safety-critical and this change does not reach them. Per the repo rule, a full
test baseline is captured **before** any edit, so a failure afterwards can be diffed
against it rather than assumed to be a regression.

Verification before the work is called done:

```bash
xcodebuild -project MobiCureVN.xcodeproj -scheme MobiCureVN \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

xcodebuild -project MobiCureVN.xcodeproj -scheme MobiCureVN \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

Both must pass, and the built screen is looked at in the simulator in Vietnamese and
English, light and dark, at standard and extraLarge text size.

## Risks

- **Pushing chat into a `NavigationStack`.** `ChatWorkspaceView` manages its own sidebar
  and full-bleed background. A system nav bar above it may crowd compact width. Mitigated
  by looking at it and falling back to `fullScreenCover`; either way the chat view's own
  body is not restructured.
- **Removing a file from `MobiCureVNTests`.** Unlike `App/`, that group is not
  filesystem-synchronized. If the removal needs a project-file change it is done through
  Xcode rather than by editing `project.pbxproj`.
- **Two "remembers" surfaces.** Home's durable card and Profile's conversation card could
  confuse a patient if labelled similarly. Mitigated by distinct wording, and reviewed
  against the `design-critique` skill before merge.
