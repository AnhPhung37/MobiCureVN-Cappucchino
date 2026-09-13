# 14 — final/chunk-splitting (contains eval-integrity; last, changes the corpus)

- Date / tester: 2026-09-14 / Claude Code (agent-executed)
- Integration commit at merge: merge commit onto `b2bc02d` (clean, no conflicts, 124 files)
- `App/Resources/vectorstore.db` shipped by this merge: 6,598,656 → 7,090,176 bytes (grew, as
  expected for more/smaller chunks)

## This resolves the doc's own outstanding TODO

Test-Protocol.md flags for this branch: "⚠️ TODO before final presentation: Run
`python -m eval.build_indexes` to rebuild neural index from 1876-chunk corpus, then re-run packing
sim to verify doc-hit seen ≥ 0.8034" — because the original tester's own "Actual" numbers were
measured against the **pre-split, stale 1238-chunk index** (their own noted caveat). Ran that
rebuild here.

## Gates

| G1 build | G2 Swift | G3 Python (pass/total) | G4 privacy | G5 smoke |
|---|---|---|---|---|
| deferred (no Swift touched) | deferred | ✅ **74/74** (+8 new) | not re-run | not run — needs device |

## Branch-specific checks

| Check | Pass criterion | Result | Pass? |
|---|---|---|---|
| `python -m ingestion.split_oversized --dry-run` | "would split 0" | **"would split 0 oversized chunks; corpus 1876 → 1876 chunks"** | ✅ |
| `python -m tools.remap_qrels --from-split-provenance` | "209 already grouped" | **"0 queries remapped... 209 already grouped... groups of 1-11 pieces (51 gold chunks were split)"** | ✅ |
| `python -m eval.build_indexes` (the TODO above) | rebuild from 1876-chunk corpus | **"neural indexed 1876 chunks (39 docs, sha256=3057e01de661)"** | ✅ |
| `python -m eval.run_eval` (post-rebuild) | coverage 1.000 | recall@5 **0.2249**, doc-hit@5 **0.7799**, MRR **0.1503**, nDCG@5 **0.1689**; FTS 0.2010/0.7177 — **exact match to the doc's "Expected" column**, coverage 1.0 | ✅ |
| Packing sim `--top-k 10 --budget 3000 --ratio 1.75` (doc-hit seen ≥ 0.8034) | — | **cannot run** — `tools/simulate_context_packing.py` missing repo-wide, see `07-context-budget-fix.md` | ⚠️ unverifiable |
| G5 citations from rebuilt `vectorstore.db` | — | needs device | ⏭ escalated |
| Quick quality vs 3.7 | — | needs raters | ⏭ escalated |

Since `doc-hit@5 = 0.7799 ≥ 0.7603` (the doc's own DROP threshold), the drop condition on that
metric is clearly not met. The `doc-hit seen (k10/3000) ≥ 0.8034` half of the DROP criterion
remains unverifiable for the same tooling-gap reason as `07`/`08` — noting rather than guessing.

## Numbers (vs previous kept step)

| Metric | Previous (chunk count 1238) | This step (1876) | Δ |
|---|---|---|---|
| recall@5 (hybrid) | 0.2488 | 0.2249 | −0.0239 (expected: more, smaller chunks compete for top-5) |
| doc-hit@5 (hybrid) | 0.7703 | **0.7799** | +0.0096 |
| MRR | 0.1589 | 0.1503 | −0.0086 |
| nDCG@5 | 0.1814 | 0.1689 | −0.0125 |
| G3 Python | 66/66 | 74/74 | +8 |

Matches the doc's own framing exactly: recall falls while doc-hit rises, because a split gold
passage now counts once whichever piece is found.

## Decision

**KEEP.** Every numeric check that could be run matches the doc's "Expected" column exactly (this
run is more complete than the original human tester's own, since the index-rebuild TODO is now
done). `doc-hit@5` clears the DROP threshold comfortably. The `doc-hit seen` half of the DROP
criterion and G5 citation rendering remain open pending the missing packing tool and device access
respectively — neither is a reason to drop a branch whose every other number matches expectation.
