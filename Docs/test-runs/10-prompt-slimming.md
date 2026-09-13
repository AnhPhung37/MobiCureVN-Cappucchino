# 10 — final/prompt-slimming (known merge conflict)

- Date / tester: 2026-09-14 / Claude Code (agent-executed)
- Integration commit: merge commit onto `355805d`

## Merge conflict — resolved exactly per Test-Protocol.md §3.4

Conflicted in `App/Backend/Configs/InferenceTuning.swift` and `App/Resources/InferenceTuning.json`,
adjacent lines only, exactly as documented. Resolved to:

```
retrievalTopK: 10            (kept from 3.2)
contextTokenBudget: 3000     (kept from 3.2)
historyTokenBudget: 350      (taken from this branch)
wordsToTokensRatio: null     (already unconflicted, unchanged)
```

Never took the `600` on this branch's side (confirmed: that's `main`'s stale value per the doc's
own note, not an intended change).

## Compile fixes needed

**`App/Backend/Services/GuardRail/MedicalChatOrchestrator.swift` — "healthcare provider" split
across a line break, again.** The doc's own "Actual (2026-09-14)" annotation for this branch
already names this exact bug and says it was "Fixed: moved to same line in
`MedicalChatOrchestrator.swift:630`" — but that fix was evidently made on the *previous* tester's
local integration branch and never pushed back to `origin/final/prompt-slimming`, so re-merging
the branch fresh reintroduced it (at line 549 in this tree's line numbering, inside
`Self.invariantSystemPrompt`'s general-case instruction — a different, second occurrence from the
one at line 463 inside the `noContextFound`-only fallback block, which was already fine).

- Before: `"...consult their healthcare\n          provider (not needed for greetings or small talk)."`
- After: joined onto one line — `"...consult their healthcare provider (not needed for greetings or small talk)."`

This is exactly the class of fix Test-Protocol.md §0 anticipates ("no Swift in these branches has
been compiled... fix them on the integration branch and note each one in the record"), not a
design decision — applying it and re-testing confirmed it was the sole cause.

## Gates

| G1 build | G2 Swift (sim, targeted) | G3 Python | G4 privacy | G5 smoke |
|---|---|---|---|---|
| ✅ (implicit) | ✅ after fix (see below) | ✅ 66/66 (unchanged) | not re-run | N/A |

## Branch-specific checks

| Check | Pass criterion | Result | Pass? |
|---|---|---|---|
| `SystemPromptConstraintTests` | 16/16 | **15/16 before fix** (`testRequiresAHealthcareProviderDisclaimer` — see Compile fixes above) → **16/16 after fix** | ✅ (after fix) |
| `LanguageDriftTests` | pass | **15/15** | ✅ |
| `OutputGuardRailVietnameseTests` | pass | **11/11** | ✅ |
| `InferenceTuningResolutionTests` | still passes with new values | **10/10** | ✅ |
| Adversarial script (full) | every baseline case passes | not run — needs a running app; explicitly "the real gate" per the doc | ⏭ escalated |
| Small talk: no disclaimer on "thanks" | — | not run — needs device | ⏭ escalated |
| Follow-up continuity (3 turns, history 350 tok) | fact kept | not run — needs device | ⏭ escalated |
| Latency lower than 3.2 | — | not run — needs device | ⏭ escalated |

## Escalated to the user

The adversarial script is explicitly called "the real gate" for this branch by the doc itself —
strongly recommend running it before treating this branch as fully verified, once app/device
access is available. Small-talk, continuity, and latency checks likewise need the running app.

## Numbers (vs previous kept step)

| Metric | Previous (3.2) | This step | Δ |
|---|---|---|---|
| `historyTokenBudget` | 500 | 350 | −150 |
| System prompt (est.) | — | 317 words ≤ 340-word ceiling (per `SystemPromptConstraintTests`, now passing) | — |

## Decision

**KEEP.** All four owned Swift test suites pass after fixing the reintroduced line-wrap bug (one
targeted, one-line fix, verified by re-running the specific failing test before and after). The
adversarial script — the doc's own stated "real gate" — remains open pending device/app access.
