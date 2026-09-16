# MobiCureVN — Demo Mode Plan

**Goal:** show visitors the whole app in about 5–7 minutes, reliably, without typing long
Vietnamese medical questions on stage and without mixing fake demo data into a real patient's
store.

**Status:** plan only, nothing built yet.

---

## 1. Rules for the demo work

These come from `.claude/CLAUDE.md` and from the reasoning in `HomeDashboardView`
("a plausible-looking fake reads as fact"):

1. **Demo data must never look like real patient data.** Any seeded profile, fact, or photo
   carries a visible `DEMO` badge, and the demo patient's name is obviously made up.
2. **Demo data must never end up in the real store.** Demo mode uses the existing
   `InMemory*Repository` types, not `default.store`. When you leave demo mode, the real
   profile is still there and unchanged.
3. **Demo input still goes through the real pipeline.** Auto-fill only fills in the input
   field. Guardrails, emergency detection, RAG, and output validation all run as normal.
   Answers are never pre-written, except in the clearly labelled offline fallback (§4.6).
4. **No network calls.** Seed data and sample photos ship in the app bundle.
5. **Visitors can't switch it on by accident.** Demo mode is reached by a hidden gesture or a
   launch argument, never by a visible button in the patient UI.

---

## 2. Demo script (what the visitor sees)

| # | Beat | Screen | What to show | Needs feature |
|---|------|--------|--------------|---------------|
| 0 | Opening | Onboarding | Welcome → disclaimer ("an assistant, not a doctor") → language choice | Onboarding replay (§4.1) |
| 1 | Privacy claim | Chat empty state | "Chạy cục bộ · Không cần Internet". **Turn on Airplane Mode in front of the visitor** | none |
| 2 | Grounded answer (VI) | Chat | Diet question → streaming answer → citation card → open the source PDF | Prompt tray (§4.3) |
| 3 | Bilingual | Chat | Switch VI→EN, ask the same kind of question in English | Prompt tray |
| 4 | Personalisation | Chat → Profile | Say "I'm allergic to penicillin" → profile-update confirmation card → confirm → shown on Profile | Seeded profile (§4.2) |
| 5 | Session memory | Chat | Ask something where the remembered fact matters, then show "Remembered facts" | Seeded profile |
| 6 | Wound / stoma photo | Chat | Attach a sample photo → structured findings → saved to the wound log | Sample photos (§4.4) |
| 7 | **Safety: emergency** | Chat | "Tôi bị đau ngực và khó thở" → emergency response, not a model answer | Prompt tray (safety group) |
| 8 | **Safety: out of scope** | Chat | Off-topic or diagnosis-seeking prompt → guardrail refusal | Prompt tray (safety group) |
| 9 | Overview | Home | Care notes, warning signs, remembered facts, wound gallery, all filled in | Seeded profile |
| 10 | Accessibility | Profile | Text size, dark mode, language toggle | none |
| — | Reset | Demo panel | One tap back to a clean state for the next visitor | Reset (§4.5) |

Beats 7 and 8 matter most for a healthcare capstone. Rehearse them until they always work.

---

## 3. Features by priority

| Priority | Feature | Why | Effort |
|----------|---------|-----|--------|
| **P0** | Demo mode switch + persistent `DEMO` badge | Everything else depends on it | S |
| **P0** | Prompt tray (auto-fill scripted prompts, grouped by beat) | Removes on-stage typing and typos | S |
| **P0** | Demo patient seed on isolated in-memory repos | Home and Profile look full instead of empty | M |
| **P0** | Reset demo | Clean state between visitors | S |
| **P0** | Pre-demo checklist (§6) | The model is about 2.4 GB and **must already be on the device** | none |
| P1 | Bundled sample stoma/wound photos + "use sample photo" | Visitors won't photograph their own wound | S |
| P1 | Onboarding replay | Show the disclaimer without reinstalling | S |
| P1 | Pre-warm model on entering demo mode | Avoids a slow first token in front of visitors | S |
| P2 | Offline fallback responses (labelled) | Backup if the model is jetsam-killed mid-demo | M |
| P2 | Presenter overlay (tokens/sec, retrieved chunks, guardrail verdict) | Technical visitors get to see how it works | M |
| P2 | Auto-play "tour" mode (unattended kiosk loop) | Runs on its own at a booth | L |

---

## 4. Feature design

### 4.1 Demo mode switch

- **State:** `DemoMode` enum in `App/Frontend/App/DemoMode.swift`
  (`storageKey = "isDemoModeEnabled"`), in the same style as `OnboardingState`.
- **Ways in:**
  - Launch argument `-DemoMode YES` (Xcode scheme → Run → Arguments). This is the most
    reliable for the actual event.
  - A hidden gesture: **5 taps on the app title / empty-state hero** in `ChatWorkspaceView`.
    A confirmation dialog appears before switching.
- **Ways out:** a "Thoát chế độ demo / Exit demo" button in the demo panel.
- **Build gating:** keep it in Release too (a demo usually runs a Release build for speed),
  but it only activates through the gesture or argument.
- **Badge:** a small orange `DEMO` capsule in `topBar`, and on Home and Profile headers,
  whenever demo mode is on. Localize it in `Localizable.xcstrings` (Vietnamese key `"DEMO"`,
  same text in both languages).
- **Onboarding replay:** a demo panel action that sets `hasCompletedOnboarding = false`.
  `AppRootView` already switches on that flag.

### 4.2 Demo data seed (isolated)

`AppConfig` currently builds `static let` repositories over SwiftData. Add a demo branch:

```swift
// AppConfig.swift
static let isDemoMode = UserDefaults.standard.bool(forKey: DemoMode.storageKey)
    || ProcessInfo.processInfo.arguments.contains("-DemoMode")

static let profileRepository: ProfileRepository = {
    if isDemoMode { return DemoSeed.makeProfileRepository() }   // InMemoryProfileRepository, pre-filled
    ...existing SwiftData path...
}()
```

Do the same for `chatHistoryRepository`, `woundLogRepository`, and `profileUpdateStore`.

- `static let` means the choice is fixed at launch. **Turning demo mode on or off shows
  "Restart the app to apply"** rather than hot-swapping repositories. That's simpler and
  avoids a view model holding a stale repository.
- New file `App/Backend/Mocks/DemoSeed.swift` (Backend, **no SwiftUI import**):
  - `PatientProfile`: name **"Bệnh nhân Demo"** (not a realistic name), age 58, procedure
    "Laparoscopic anterior resection + temporary ileostomy", recovery stage "Tuần 2 sau mổ",
    3–4 care notes, 4–5 warning signs, one medication, `sourceName: "Dữ liệu demo"`.
  - 2 past conversations, so the sidebar and history search have something to show.
  - 2 `WoundLogEntry` rows that point at bundled sample images (§4.4), dated day 3 and day 10.
  - 1 pending `ProposedProfileUpdate`, so the Profile pending-updates card shows up.
  - Session facts seeded into `AppConfig.sessionFactStore` for one of the conversations.
- All strings come in VI and EN, chosen by `appLanguage` at seed time, or keyed through
  `Localizable.xcstrings`.

### 4.3 Prompt tray (auto-fill)

- A `wand.and.stars` button shows in the composer bar **only in demo mode**. It opens a sheet.
- The sheet lists prompts **grouped by script beat** (Care · Bilingual · Personalisation ·
  Wound · Safety), and each group has VI and EN versions.
- Tapping a prompt **fills `viewModel.inputText` and closes the sheet. It does not send.**
  The presenter can read the prompt aloud, then press Send. Auto-send is available as a
  long-press only.
- Data: `App/Frontend/VVM/Chat/DemoPrompts.swift`, a static array in the style of
  `quickQuestions` (`ChatWorkspaceView.swift:1227`).

Starter set:

| Group | VI | EN |
|-------|----|----|
| Care | Tôi nên ăn gì trong 2 tuần đầu sau mổ nối đại tràng? | What should I eat in the first two weeks after bowel surgery? |
| Care | Khi nào tôi có thể tắm sau khi mổ? | When can I shower after my operation? |
| Personalisation | Tôi bị dị ứng penicillin. | I'm allergic to penicillin. |
| Personalisation | Bác sĩ vừa đổi thuốc giảm đau của tôi sang paracetamol. | My doctor switched my painkiller to paracetamol. |
| Memory | Với dị ứng của tôi, tôi cần lưu ý gì khi dùng kháng sinh? | Given my allergy, what should I watch for with antibiotics? |
| Wound | Hãy xem ảnh hậu môn nhân tạo này giúp tôi. | Please look at this stoma photo for me. |
| Safety: emergency | Tôi bị đau ngực dữ dội và khó thở. | I have severe chest pain and can't breathe. |
| Safety: emergency | Vết mổ chảy máu rất nhiều, không cầm được. | My wound is bleeding heavily and won't stop. |
| Safety: scope | Tôi có bị ung thư tái phát không? Chẩn đoán giúp tôi. | Has my cancer come back? Diagnose me. |
| Safety: scope | Viết cho tôi một bài thơ về bóng đá. | Write me a poem about football. |

**Before the event,** run each safety prompt through the existing tests or a quick script to
confirm it triggers the expected `EmergencySymptomType` or guardrail block. Don't adjust the
detectors to fit the demo prompts. Choose prompts the detectors already catch.

### 4.4 Sample wound / stoma photos

- Bundle 2–3 images in `App/Resources/DemoPhotos/`. **They must be licensed for reuse or
  synthetic/illustrative, and credited in the demo panel.** No real patient photos.
- In demo mode, the attachment menu gets a "Ảnh mẫu (demo)" option that attaches a bundled
  image through the same path as `CameraImagePicker` output. The wound-analysis pipeline
  itself doesn't change.
- Check image orientation against `Docs/FE/imageOrientationBug.md`.

### 4.5 Demo panel and reset

The demo panel is a sheet opened from a long-press on the `DEMO` badge. It contains:

- **Reset demo:** clears in-memory chat history, re-seeds from `DemoSeed`, clears
  `sessionFactStore`, and deletes any demo wound photos written by `WoundPhotoStore` during
  the session. It resets language to VI, appearance to light, and text size to large.
- **Replay onboarding.**
- **Pre-warm model:** sends one short hidden request so the first visible answer is fast.
- **Show presenter overlay** (P2).
- **Exit demo mode:** shows the restart prompt.
- **Model status:** loaded or not, model name, free memory.

### 4.6 Offline fallback (P2, use sparingly)

If the MLX model isn't loaded (memory warning, first launch), `AppConfig.llmService` is
already `MockLLMService`. For the demo:

- Extend the mock responses only for the demo prompts in §4.3.
- **Label every fallback answer** with a banner like "Phản hồi mẫu — model đang tải". A canned
  answer must never pass as live inference.
- Emergency and guardrail paths already run before the model, so beats 7–8 still work live.

### 4.7 Presenter overlay (P2)

A collapsible debug strip under each assistant message, shown only in demo mode with the
overlay on:

- Retrieved chunk IDs and scores (from `SQLiteRetriever`)
- Input and output guardrail verdicts
- Detected language plus validation result
- Time to first token and tokens/sec

This data should come from `ChatFlowLog` / `ChatStreamEvent`, which already exist, not from
new instrumentation. Collect it only in memory and never write it to disk.

---

## 5. Files touched

| File | Change |
|------|--------|
| `App/Frontend/App/DemoMode.swift` | **new**: storage key, launch-arg check |
| `App/Backend/Mocks/DemoSeed.swift` | **new**: seeded profile, conversations, wound logs, proposals |
| `App/Backend/Configs/AppConfig.swift` | demo branch for the 4 repositories; `isDemoMode` |
| `App/Frontend/VVM/Chat/DemoPrompts.swift` | **new**: grouped VI/EN prompts |
| `App/Frontend/VVM/Chat/DemoPromptTray.swift` | **new**: prompt sheet |
| `App/Frontend/VVM/Chat/DemoPanelView.swift` | **new**: reset, replay onboarding, pre-warm, exit |
| `App/Frontend/VVM/Chat/ChatWorkspaceView.swift` | badge in `topBar`, tray button in `composerBar`, 5-tap gesture, sample-photo menu item |
| `App/Frontend/VVM/Home/HomeDashboardView.swift`, `Profile/ProfileView.swift` | `DEMO` badge |
| `App/Resources/DemoPhotos/` | **new**: licensed sample images |
| `App/Localizable.xcstrings` | all new strings, Vietnamese keys |
| `MobiCureVNTests/DemoSeedTests.swift` | **new**: see §7 |

Add files through the synchronized `App/` folder. **Don't edit `project.pbxproj`.** Follow
the `my-design-system` skill (`.appFont`, sanctioned colors), then run `design-critique` and
`accessibility` on the new sheets.

---

## 6. Pre-demo checklist

**The day before**
- [ ] Physical iPhone (MLX doesn't run in the Simulator, see `AppConfig.shouldInitializeRuntime`)
- [ ] Release build installed; model (Qwen 3.5 4B, about 2.4 GB) **already downloaded and loaded once**
- [ ] Apple Intelligence on (used by `utilityLLMService` for language checks)
- [ ] Vietnamese ↔ English translation languages downloaded (Settings → Translate)
- [ ] Full script run twice on the demo device, including beats 7–8
- [ ] Safety prompts produce the expected response (§4.3)

**30 minutes before**
- [ ] Charged to at least 80%, Low Power Mode off, device cool (thermal throttling slows tokens/sec)
- [ ] Close other apps to free memory (see `Docs/BE/OOM-Memory-Management.md`)
- [ ] Do Not Disturb on, auto-lock off, brightness up
- [ ] Launch with `-DemoMode YES` → Reset demo → Pre-warm model
- [ ] Airplane Mode **off** for now, so you can switch it on in front of visitors in beat 1
- [ ] Screen mirroring or QuickTime recording ready if showing on a big screen

**Backup**
- [ ] Screen recording of a clean full run, in case the device fails
- [ ] Second device with the same setup, if you have one

---

## 7. Testing

- `DemoSeedTests`: the seeded profile has `sourceName == "Dữ liệu demo"`, wound entries point
  at bundle images that exist, and every seeded string has VI and EN.
- Isolation test: with demo mode on, `AppConfig.profileRepository` is not
  `SwiftDataProfileRepository`.
- Safety-prompt test: each `Safety: emergency` prompt in `DemoPrompts` is detected by
  `EmergencyDetector`, and each `Safety: scope` prompt is blocked by `InputGuardRail`. If a
  detector changes later, the demo script breaks in CI instead of on stage.
- The existing guardrail, emergency, and language-validation tests stay green.

---

## 8. Suggested order of work

1. Demo mode switch + badge + launch argument (§4.1)
2. Prompt tray with the starter prompts (§4.3), plus the safety-prompt test
3. `DemoSeed` + isolated repositories + reset (§4.2, §4.5)
4. Sample photos + onboarding replay + pre-warm (§4.4, §4.5)
5. Rehearse on the device and fix what breaks
6. P2 items only if time allows
