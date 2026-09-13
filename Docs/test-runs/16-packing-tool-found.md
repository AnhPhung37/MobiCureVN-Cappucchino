# 16 — packing-simulation tool located; retroactive results and a corpus-timing caveat

- Date / tester: 2026-09-14 / Claude Code (agent-executed)

## Where it was

`Pipeline/tools/simulate_context_packing.py`, flagged as missing repo-wide in
`07-context-budget-fix.md`, ships with **`final/multilang-embedder-and-test-protocol`** (step 4.2)
— the same branch that adds `Docs/Test-Protocol.md` itself. Not obvious from the branch name, and
not found by searching context-budget-fix/retrieval-topk/chunk-splitting/mlx-runtime-knobs/
prefix-kv-cache/prompt-slimming, so it went unnoticed until merging this branch in sequence.

## What was run, and the corpus-timing caveat

The tool reads the **current, on-disk retrieval index** — it doesn't reconstruct the corpus as it
existed at a given historical commit. By the time this branch (last in the merge order) made the
tool available, `final/chunk-splitting` (step 3.8, merged earlier) had already taken the corpus
from 1238 → 1876 chunks. So:

- The `--top-k 10 --budget 3000 --ratio 1.75` run below is **exactly** what `chunk-splitting`'s own
  check wants (that check is explicitly defined as "after the rebuild," i.e. against the 1876-chunk
  corpus) — this one is a clean, apples-to-apples result.
- The `--policy old --top-k 5 --budget 600` (§2.6 baseline) and `--policy new --top-k 5 --budget
  2000` (`context-budget-fix`'s own check) runs are measured against that **same current,
  post-split corpus** — not the 1238-chunk corpus that existed when those two branches were
  originally merged and tested. They're internally consistent with each other (both on the current
  corpus, so the *relative* before/after-fix comparison is valid and the zero-context claim is
  still meaningfully checked), but their absolute numbers should not be read as confirming or
  contradicting the doc's own historical figures for those two specific branches, which were
  measured at an earlier corpus state.

Re-deriving true point-in-time numbers would mean checking out and rebuilding the index at each
historical commit — treated as out of scope for a test pass (that's reconstructing history, not
testing what's on `origin` now).

## Results

| Run | Command | sent | ctx tok | zero-ctx | doc-hit seen | Matches doc? |
|---|---|---|---|---|---|---|
| §2.6 baseline (old policy, **current corpus**) | `--policy old --top-k 5 --budget 600 --ratio 1.4` | 1.96 | 451 | **0.0%** | 0.6029 | Not comparable — see caveat (doc: 1.52 / 22.5% / 0.4450, on the 1238-chunk corpus) |
| `context-budget-fix` (new policy, **current corpus**) | `--policy new --top-k 5 --budget 2000 --ratio 1.75` | 4.86 | 1679 | **0.0%** | 0.7751 | Zero-context claim ✅ confirmed; absolute doc-hit not comparable (doc: 4.51 / 0.0% / 0.7416, on the 1238-chunk corpus) |
| `retrieval-topk` / `chunk-splitting` (new policy, topK10/3000, **current corpus**) | `--policy new --top-k 10 --budget 3000 --ratio 1.75` | **8.50** | 2848 | **0.0%** | **0.8421** | **Exact match to `chunk-splitting`'s own expected row** (8.50 sent, doc-hit seen 0.8421) — this is the intended post-rebuild measurement |

The third row directly closes `chunk-splitting`'s own DROP criterion: **0.8421 ≥ 0.8034** —
clears comfortably. See `14-chunk-splitting.md`, updated to reference this.

Raw JSON: `packing-baseline.json`, `packing-context-budget-fix.json`, `packing-retrieval-topk.json`
(all in this directory).

## What this changes in earlier records

- `06-baseline.md`: packing baseline is no longer purely "cannot run" — a same-corpus
  reconstruction now exists, with the caveat above.
- `07-context-budget-fix.md`: the branch's zero-context claim (0.0%) is now independently
  confirmed; the absolute doc-hit-seen number is not a clean historical match.
- `08-retrieval-topk.md`: same status as `07` — zero-context confirmed, absolute number not a
  clean historical match (the clean match landed under `chunk-splitting` instead, since that's the
  corpus state this run actually reflects).
- `14-chunk-splitting.md`: **fully resolved** — exact match, DROP threshold cleared.

None of this changes any branch's KEEP decision — every affected branch was already KEPT on the
strength of its own Swift/Python test suite, with the packing number as a secondary, now
partially-recovered data point.
