# 06 — BASELINE (§2.6), measured after Phase 1, before Phase 2

- Date / tester: 2026-09-14 / Claude Code (agent-executed)
- Integration commit: tip of Phase 1 (`01f1074`, all of eval-integrity through latency-benchmark merged)

| Measurement | How | Result |
|---|---|---|
| Retrieval | §2.1 `run_eval` numbers | Already recorded in `01-eval-integrity.md`: hybrid recall@5 0.2488, doc-hit@5 0.7703, MRR 0.1589, nDCG@5 0.1814; FTS-only 0.2201/0.7081 — confirmed identical across 4 runs, `dirty:false`. |
| Packing | `python -m tools.simulate_context_packing --policy old …` | **Update — the tool actually ships with `final/multilang-embedder-and-test-protocol` (step 4.2), not `context-budget-fix`.** Run retroactively once merged; see `16-packing-tool-found.md`. Result: 1.96 chunks sent, 0.0% zero-ctx, doc-hit seen 0.6029 — measured against the *current* (post-`chunk-splitting`, 1876-chunk) corpus, not the 1238-chunk corpus that existed at the true Phase-1/Phase-2 boundary, so not directly comparable to what a same-day baseline would have shown. Recorded as the best available reconstruction, not a historical baseline. |
| Latency | harness on iPad M5 → `latency-baseline.json` | ⏭ escalated — needs physical device access (pending permission grant, see `01-eval-integrity.md`) |
| Peak memory | Instruments → Allocations, one long answer | ⏭ escalated — manual Instruments GUI session, needs a human |
| Answer quality | 30-question sheet, two raters | ⏭ escalated — needs two human raters (tooling already verified in `04-answer-quality.md`) |
| Adversarial | `Docs/BE/Adversarial-Chat-Test-Script.md` | ⏭ escalated — needs a running app + human judgment on each case |

No baseline p95 time-to-final available yet (blocked on device access), so the "regress ≤10% vs
previous step" fallback rule from §2.6 can't be evaluated numerically until the device run lands.
Will apply retroactively once the opt-in latency harness runs.
