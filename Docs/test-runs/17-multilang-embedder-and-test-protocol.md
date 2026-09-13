# 17 — final/multilang-embedder-and-test-protocol (this branch; contains eval-integrity)

- Date / tester: 2026-09-14 / Claude Code (agent-executed)
- Integration commit at merge: merge commit onto `5a8e174` (clean, no conflicts)
- Device: this Mac, `--device mps` (doc's own CPU run was on the Mac Studio; MPS used here as the
  closest available Apple Silicon acceleration — see comparison below)

## Gates

| G1 build | G3 Python (pass/total) | G4 privacy |
|---|---|---|
| deferred (no Swift changed) | ✅ 74/74 (unchanged) | standing bash-3.2 finding, no new issues |

## Branch-specific checks

`python -m tools.compare_embedders --device mps --out ../Docs/test-runs/embedder-comparison.json`
— `queries_vi.jsonl` prerequisite already present (merged in via `final/answer-quality` earlier in
this sequence; the doc's manual `git show final/answer-quality:...` step was a no-op here).

| Embedder | EN doc-hit@5 | VI same-doc@5 | Matches doc's CPU run? |
|---|---|---|---|
| bge-small-en-v1.5 (current) | 0.7943 | 0.583 | ✅ exact |
| multilingual-e5-small | 0.7847 | 0.500 | ✅ exact |
| **bge-m3** | **0.7990** | **1.000** | ✅ exact |

Every metric matches the doc's own "Actual (2026-09-14, CPU run)" table exactly, despite running on
MPS instead of CPU and on this Mac instead of the Mac Studio — a good determinism signal. **bge-m3
remains the clear recommendation**: best EN doc-hit@5 *and* perfect VI→EN same-document retrieval,
confirming the doc's own verdict.

## The packing-simulation tool

This branch is where `Pipeline/tools/simulate_context_packing.py` actually lives — see
`16-packing-tool-found.md` for the full account and the retroactive results for `06-baseline.md`,
`07-context-budget-fix.md`, `08-retrieval-topk.md`, and `14-chunk-splitting.md` (the last of which
is now fully, exactly resolved).

## Decision

**KEEP.** Investigation-only branch; every number reproduces exactly. bge-m3 is confirmed as the
multilingual replacement candidate, gated behind the tokenizer parity test the handoff doc (§5)
already calls for — no swap performed here, matching the doc's own "future work" framing.
