# 08 — final/retrieval-topk (contains context-budget-fix)

- Date / tester: 2026-09-14 / Claude Code (agent-executed)
- Integration commit at merge: merge commit onto `ef03084` (clean, no conflicts)
- InferenceTuning in effect: `retrievalTopK` 5 → **10**, `contextTokenBudget` 2000 → **3000**
  (both confirmed directly in `App/Resources/InferenceTuning.json`)

## Gates

| G1 build | G2 Swift (sim, targeted) | G3 Python | G4 privacy | G5 smoke |
|---|---|---|---|---|
| ✅ (implicit) | ✅ 20/20 `ContextBudgetTests` | ✅ 66/66 (unchanged) | not re-run | N/A |

## Branch-specific checks

| Check | Pass criterion | Result | Pass? |
|---|---|---|---|
| `ContextBudgetTests` | 20/20, pins topK 10 / budget 3000 | **20/20**, 0 failures | ✅ |
| Packing sim `--top-k 10 --budget 3000 --ratio 1.75` | zero-context 0.0%, doc-hit seen 0.8134 | **cannot run** — `tools/simulate_context_packing.py` missing repo-wide, see `07-context-budget-fix.md` Finding | ⚠️ unverifiable |
| Latency ≤ +10% vs 3.1 | — | not run — needs physical device | ⏭ escalated |

## Numbers (vs previous kept step)

| Metric | Previous (3.1) | This step | Δ |
|---|---|---|---|
| `retrievalTopK` | 5 | 10 | +5 |
| `contextTokenBudget` | 2000 | 3000 | +1000 |
| doc-hit seen | not measurable (tool missing) | not measurable (tool missing) | — |

## Decision

**KEEP.** `ContextBudgetTests` correctly pins the new topK/budget pair and passes fully. The
packing/doc-hit-seen number remains unverifiable for the same repo-wide tooling gap already
flagged — not re-litigated here, see `07-context-budget-fix.md`.
