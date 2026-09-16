# Frontend Inconsistencies & Refactor Backlog — MobiCureVN

Last updated: 2026-07-08

## Overview

This document catalogs UI inconsistencies and refactor opportunities found across the
SwiftUI frontend (`App/Frontend/VVM/`). It is a working backlog: each item lists the
symptom, concrete locations (`file:line`), and the recommended fix. Items are grouped by
theme and ordered by impact.

> **Update (#54, 2026-09-15):** `HomeContentView.swift` and the medication screens
> (`Medication.swift`, `MedicationListView.swift`, `DayDetailView.swift`,
> `AddMedicationView.swift`) were deleted when the Home screen was rebuilt on real
> data. Findings that pointed only at those files have been dropped from the tables
> below; everything else still stands.

Scope of files reviewed:
- `Chat/ChatView.swift`, `Chat/MessageBubble.swift`, `Chat/CitationCard.swift`
- `Home/HomeView.swift`, `Home/HomeDashboardView.swift`
- `Profile/ProfileView.swift`

---

## 1. Language inconsistency (highest priority)

The app positions itself as Vietnamese-first, but UI copy mixes English and Vietnamese
without a clear rule, and all strings are hardcoded (no `Localizable.strings`).

| Symptom | Location |
| --- | --- |
| ProfileView is almost entirely English (`"Care notes"`, `"Warning signs"`, `"Age"`, `"Gender"`, `"Procedure"`, `"Loading profile..."`, `"Report summary"`) | `ProfileView.swift:16-24, 89-94` |
| Hardcoded Vietnamese strings scattered inline (e.g. `"Đang tải model..."`) | `ChatView.swift:258, 516` |

**Fix:** Choose Vietnamese as the primary language, extract all user-facing strings into
`Localizable.strings` (with an English variant), and adopt `LocalizedStringKey`
throughout. This also enables proper bilingual support instead of ad-hoc `"VN / EN"`
concatenated strings.

---

## 2. Dead UI and fake/hardcoded data

Buttons that do nothing and static placeholder content make the app feel broken/unfinished.

| Symptom | Location |
| --- | --- |
| `clearButton` computed property defined but never used (dead code) | `ChatView.swift:448` |

**Fix:** Wire each control to real data/actions, or hide it until implemented. Remove dead
code. Drive greeting name and streak from the patient profile / a real journey model.

---

## 3. Accessibility (critical for a medical app)

Target users may be post-surgery / older patients — accessibility is a functional
requirement, not polish.

| Symptom | Location |
| --- | --- |
| Fixed font sizes everywhere (`.font(.system(size: 16))`) instead of Dynamic Type — does not scale with system text size | pervasive across all views |
| Hint text at `size: 10` with `.tertiaryLabel` is near-unreadable | `ChatView.swift:341` |
| State conveyed by color only — the status badge dot lacks a secondary (icon/text) indicator for color-blind users | `ChatView.swift:494` |

**Fix:** Replace fixed sizes with semantic text styles (`.body`, `.headline`, ...). Add
`.accessibilityLabel` to all icon-only controls. Pair every color status with an
icon/text.

---

## 4. Missing design system (design tokens)

No centralized tokens for color, spacing, radius, or typography leads to arbitrary values.

| Symptom | Location |
| --- | --- |
| Corner radii used arbitrarily: 12/14/16/18/20/22/24/28 with no rule | pervasive |
| Color mismatch: ProfileView hardcodes `.cyan` everywhere; Chat/Home use `.accentColor` | `ProfileView.swift` vs `ChatView.swift` |
| Card background hierarchy unclear: `.systemBackground` / `.secondarySystemBackground` / `.tertiarySystemBackground` mixed without a rule | pervasive |

**Fix:** Introduce a `Theme`/`DesignTokens` namespace (colors, spacing scale, radius scale,
typography) and refactor views to consume it. Standardize on `.accentColor`. Verify dark
mode.

---

## 5. Loading / empty / error states

| Symptom | Location |
| --- | --- |
| Profile loading is a bare spinner (`ProgressView("Loading profile...")`) — no skeleton | `ProfileView.swift:14-16` |
| Chat status badge shows developer jargon to end users (`"Mock service"`, `"Mock + model downloaded"`) | `ChatView.swift:508-509` |

**Fix:** Add skeleton loaders, empty-state views, and user-friendly status copy.

---

## 6. Chat experience

| Symptom | Location |
| --- | --- |
| No per-message timestamp or copy button (text selection is enabled but not discoverable) | `MessageBubble.swift` |
| Suggestion chips only appear in the empty state; no follow-up suggestions after replies | `ChatView.swift:401-444` |
| No haptic feedback on send | `ChatView.swift:369` |
| Auto-scroll triggers on `messages.last?.content` change — can stutter during fast token streaming | `ChatView.swift:320` |

**Fix:** Add message metadata (timestamp/copy), consider follow-up suggestions, add haptics,
and debounce/throttle auto-scroll.

---

## Recommended sequencing

1. **Language unification** + extract `Localizable.strings` (Section 1). Highest perceived-quality impact.
2. **Dead UI / fake data** cleanup (Section 2). Removes "broken app" feel.
3. **Dynamic Type + design tokens** (Sections 3 & 4). Foundational; unblocks consistent future work.
4. **States & chat polish** (Sections 5 & 6). Incremental refinement.
