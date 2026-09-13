# 02 — final/docs-metrics-truth

- Date / tester: 2026-09-14 / Claude Code (agent-executed)
- Integration commit at merge: merge commit onto `7933268` (docs-only, no conflicts)
- Devices: n/a — docs-only branch, no Swift/build surface touched
- Model under test: n/a

## Gates

| G1 build | G2 Swift | G3 Python (pass/total) | G4 privacy | G5 smoke |
|---|---|---|---|---|
| not run (docs-only; no Swift file in the diff) | not run (same reason) | ✅ 44/44 | N/A (not yet merged) | N/A |

## Compile fixes needed

None.

## Branch-specific checks

| Check | Pass criterion | Result | Pass? |
|---|---|---|---|
| `git grep -nw "1\.00" -- Docs ':!Docs/Test-Protocol.md'` | every hit is the retracted leaked-label result, quoted as retracted | 4 hits: `Docs/BE/nextStep.md:44,201`, `Docs/Eval-Integrity-Finding.md:24,168` — all quote or explicitly discuss the retracted figure | ✅ |
| `git grep -nE "(^|[^0-9])9-doc\|0\.367" -- Docs ':!Docs/Test-Protocol.md'` | every hit is correction/history/legacy context, none presents a 9-doc index as current | 5 hits: `Docs/Eval-Integrity-Finding.md:11,29,60`, `Docs/RAG-Pipeline-and-Evaluation.md:245,308` — all correction narrative or explicitly-flagged-legacy | ✅ |

Exact match to Test-Protocol.md's own "Actual (2026-09-14)" annotation for this branch.

## Numbers (vs previous kept step)

No behavior change — docs only. G3 stayed at 44/44 (same as `final/eval-integrity`).

## Decision

**KEEP.** Both greps match expected context exactly; G3 unaffected.
