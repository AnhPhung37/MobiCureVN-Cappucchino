# 07 — final/context-budget-fix

- Date / tester: 2026-09-14 / Claude Code (agent-executed)
- Integration commit at merge: merge commit onto `436e4dd` (clean, no conflicts)
- Devices: simulator iPhone 17 Pro (26.4.1) for Swift tests; physical iPad checks escalated
- InferenceTuning in effect: `contextTokenBudget` 600 → **2000** (confirmed in
  `App/Resources/InferenceTuning.json`); `wordsToTokensRatio` global constant (1.4) → **null**,
  now resolved per-model via `ModelCatalog.wordsToTokensRatio` (confirmed: `.qwen3_5_4B`
  (the current `ModelCatalog.default`) → **1.75**, matching the doc exactly)

## Gates

| G1 build | G2 Swift (sim, targeted) | G3 Python (pass/total) | G4 privacy | G5 smoke |
|---|---|---|---|---|
| ✅ (implicit — test target built successfully) | ✅ 29/29 (`ContextBudgetTests` + `InferenceTuningResolutionTests`) | ✅ 66/66 (unchanged — no Python touched) | not re-run | N/A |

## Branch-specific checks

| Check | Pass criterion | Result | Pass? |
|---|---|---|---|
| `ContextBudgetTests` | 19/19 | **19/19**, 0 failures | ✅ |
| `InferenceTuningResolutionTests` | 10/10 | **10/10**, 0 failures | ✅ |
| Packing sim `--policy new --top-k 5 --budget 2000 --ratio 1.75` | zero-context 0.0% | **Update — tool found, see `16-packing-tool-found.md`.** Re-run on the current (post-`chunk-splitting`) corpus: 0.0% zero-ctx confirmed, doc-hit seen 0.7751 — not a clean historical match, since this branch's own corpus was 1238 chunks, not today's 1876 | ✅ (zero-ctx claim) |
| Stale seed / knob-is-live / citations / latency ≤5s | various | not run — needs physical device | ⏭ escalated |

## Finding: `tools/simulate_context_packing.py` does not exist anywhere in the repository

Searched the merged tree, `origin/final/context-budget-fix`, `origin/final/retrieval-topk`,
`origin/final/chunk-splitting`, `origin/final/mlx-runtime-knobs`, `origin/final/prefix-kv-cache`,
and `origin/final/prompt-slimming` (every branch that could plausibly own it) via
`git ls-tree -r <ref> --name-only`. **No branch on `origin` contains this file.** Current
`Pipeline/tools/` after this merge: `ab_retrieval.py`, `convert_embedder.py`,
`make_answer_sheet.py`, `measure_token_ratio.py`, `remap_qrels.py`, `score_answer_sheet.py`,
`smoke_retrieve.py` — no packing simulator among them.

This tool is central to both docs — cited for the §2.6 baseline, and for this branch's,
`final/retrieval-topk`'s, and `final/chunk-splitting`'s own core pass criteria (the "zero-context
drops to 0%" claims). All of those specific numeric checks are **unverifiable as written** with
what's actually been pushed. The doc's own "Actual (2026-09-14)" annotations for these branches
already contain packing numbers (e.g. this branch's "0.0% zero-ctx; 3.90 chunks..."), so whoever
ran it before had a working copy of this script — it was apparently never committed. Flagging
this for the user rather than fabricating numbers or reconstructing the tool myself (writing a new
implementation of an eval tool that's supposed to already exist and be exercised as-is would mean
testing my own reconstruction, not the branch).

`Pipeline/tools/measure_token_ratio.py` (which *did* ship with this branch) was not independently
re-run here — its output is already baked into `ModelCatalog.wordsToTokensRatio`'s committed
values, which is the artifact that actually matters at runtime.

## Escalated to the user

- Packing-simulation numbers (this branch, retrieval-topk, chunk-splitting) — tool missing, see
  Finding above. Recommend locating the original script (may exist locally on whoever's machine
  ran the "Actual (2026-09-14)" numbers already in `Test-Protocol.md`) and committing it, or
  confirming it should be reconstructed as new work (out of scope for a test pass).
- Stale-seed log line, live-knob-via-Documents-override, citation-card grounding check, latency
  p95 — all need the physical iPad.

## Numbers (vs previous kept step)

| Metric | Previous | This step | Δ |
|---|---|---|---|
| `contextTokenBudget` | 600 | 2000 | +1400 |
| `wordsToTokensRatio` (default model) | 1.4 (global) | 1.75 (per-model, qwen3_5_4B) | — |
| doc-hit@5 / doc-hit seen | 0.7703 / — | unchanged (retrieval untouched by this branch) / not measurable (tool missing) | — |

## Decision

**KEEP.** Both owned Swift test suites pass fully (29/29), and the config change matches the
doc's description exactly by direct inspection. The packing-simulation numeric claim is neither
confirmed nor contradicted — it's simply unmeasurable right now with what's in the repo. Not a
reason to drop a bug-fix branch whose own tests are green; flagged as an open item instead.
