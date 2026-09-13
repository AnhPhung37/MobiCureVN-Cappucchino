# 01 — final/eval-integrity

- Date / tester: 2026-09-14 / Claude Code (agent-executed)
- Integration commit at merge: `7933268` (fast-forward, no conflicts)
- Devices: this Mac (Xcode 26.4.1) — simulator iPhone 17 Pro (26.4.1); physical "Tech's iPad"
  (iOS 26.6, UDID 00008142-000509313E06401C)
- Model under test: n/a for this branch (retrieval/embedder only, no LLM generation change)
- InferenceTuning in effect: bundled defaults, unchanged by this branch

## Gates

| G1 build | G2 Swift (sim) | G2 Swift (iPad) | G3 Python (pass/total) | G4 privacy | G5 smoke |
|---|---|---|---|---|---|
| ✅ BUILD SUCCEEDED | ⚠️ see below | pending | ✅ 44/44 | N/A (added by `final/privacy-audit`, not yet merged) | N/A (needs `final/privacy-audit` + human; not yet applicable) |

**G2 simulator, full scheme (`MobiCureVNTests` + `MobiCureVNUITests`), parallel clones (default):**
320 passed, 10 failed. All 10 failures investigated individually (see Findings) — **none caused
by this branch**.

## Compile fixes needed

None from the merge itself. Two CLI-only environment flags were required for *any* build on this
machine (recorded once in `00-environment-setup.md`, not specific to this branch):
`-skipPackagePluginValidation -skipMacroValidation`.

## Branch-specific checks (§2.1 / Automated-Test-Execution-Plan.md §3)

| Check | Pass criterion | Result | Pass? |
|---|---|---|---|
| Python tests | all pass | 44/44 | ✅ |
| `python -m eval.build_indexes` | 1238 chunks / 39 docs | 1238 chunks / 39 docs, sha256=e61cc5aca99c | ✅ |
| `python -m eval.run_eval` ×4* | coverage 1.000; `dirty: false`; identical | hybrid recall@5 0.2488, doc-hit@5 0.7703, MRR 0.1589, nDCG@5 0.1814; FTS-only 0.2201/0.7081 — identical across all 4 runs; coverage 1.0 each time; `dirty:false` once the tree was cleaned of my own uncommitted scratch files (see note) | ✅ |
| `QueryEmbedderParityTests` | 3/3, cosine ≥ 0.999 | 3/3 passed on simulator (0.51s / 0.15s / 0.01s) | ✅ (device run pending) |
| DEBUG log, no "vector search disabled" | line absent | confirmed absent from full simulator test log | ✅ |

\* Ran 4 times, not 3: the first run showed `dirty: true`, traced to my own uncommitted
`Docs/test-runs/00-environment-setup.md` (not a harness-derived path, so correctly *not*
excluded by `provenance.py`'s dirty check). Committed it, re-ran once more clean → `dirty: false`.
Not a branch defect — a sequencing artifact of writing records before measuring. Going forward,
committing each record before the next measurement avoids this.

## Findings — investigated, not caused by this branch

**4 pre-existing `MobiCureVNTests` failures on `main` itself (guardrail tests), unrelated to any
`final/*` branch:**

- `InputGuardRailTests.testBlocksNonMedicalQuery_Entertainment` / `_Tech` / `testBlocksVeryShortQuery`
- `OutputGuardRailTests.testBlocksLowConfidenceMedicalAdvice`

All 4 reproduce **deterministically** (confirmed via an isolated, non-parallel re-run — not
simulator flakiness). Root-caused by reading source, not guessed:

- `App/Backend/Services/GuardRail/InputGuardRail.swift`'s own doc comment states it was
  **deliberately** changed to no longer gate on topic/medical-relevance — that responsibility
  moved to the LLM system prompt (see the file's header comment, lines 3–15). The three
  `InputGuardRailTests` failures assert the *old*, removed behavior.
- `OutputGuardRail.swift`'s confidence-gate only fires when `isMedicalAdvice(response)` is true,
  which checks `GuardRailRules.medicalAdvicePhrases` for substrings like `"you should take"` /
  `"apply this"`. The test's fixture text — *"You should apply ice to reduce swelling."* — matches
  none of them, so the gate never engages.
- **Confirmed pre-existing, not introduced by this merge**: `git diff --stat` between `main`
  (`5468933`) and this branch's tip touches only `App/Backend/Services/RAG/*`,
  `Pipeline/eval/*`, and new resource/test fixtures — zero overlap with `GuardRail*.swift` or
  `GuardRailRules.swift`. Those files are byte-identical to `main`, so the same deterministic
  logic must fail identically there.

**This is a pre-existing gap on `main`, outside the scope of any `final/*` branch**, but flagged
prominently per CLAUDE.md's "guardrail... must keep those green" rule: `main`'s guardrail suite is
not currently green, independent of this test campaign. Recommend the user decide whether to
update the 4 tests to match the intentional design change (documented in `InputGuardRail.swift`'s
own comment) or treat this as a real coverage gap — that's a product/safety judgment call this
agent should not make unilaterally.

**6 `AppNavigationUITests` failures on the simulator run**, all downstream of one
`FBSOpenApplicationServiceErrorDomain … RequestDenied` simulator launch failure on one of 3
parallel clones — classic simulator resource contention when parallel-testing spins up multiple
clones. Not chased further: `AppNavigationUITests` isn't part of any documented gate criterion in
either doc, and the failure signature (SpringBoard launch denial, inconsistent pass/fail for the
*same* test across clones/retries within one run) doesn't match the guardrail failures'
100%-reproducible-in-isolation signature.

## Numbers (vs previous kept step)

This is the first branch merged — no previous step to diff against. See
`00-environment-setup.md` for the bare-`main` baseline (G1 build only; G3/G4 not measurable pre-merge).

| Metric | Previous | This step | Δ |
|---|---|---|---|
| doc-hit@5 (hybrid) | — | 0.7703 | — |
| doc-hit@5 (FTS-only) | — | 0.7081 | — |
| recall@5 (hybrid) | — | 0.2488 | — |

Artifacts: `Pipeline/eval/results/eval_20260913T220243Z.json` (clean, `dirty:false` run).

## Decision

**KEEP.** Every check this branch owns passes. The 10 test failures observed alongside it are
independently confirmed pre-existing/environmental, not caused by this merge — see Findings above,
especially the guardrail-suite finding which needs the user's attention on its own track.

(iPad physical-device G2 run pending — appended below once complete.)
