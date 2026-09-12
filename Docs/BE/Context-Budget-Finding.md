# The context budget was discarding 70% of retrieval

_Measured 2026-09-12 over the 209-query golden set, index `55025e8fb094` (1238 chunks / 39 docs)._

Retrieval was never the bottleneck. The bottleneck sat between retrieval and the model.

---

## What was happening

Three things combined:

1. **`applyContextBudget` used `break`, not `continue`** — on the first chunk too large to
   fit, every chunk behind it was discarded, however small.
2. **The budget was 600 tokens** — and it was a *dead knob*: `MedicalChatOrchestrator`
   read a hardcoded `private static let contextTokenBudget = 600` while
   `InferenceTuning.Prompt.contextTokenBudget` existed and was parsed from
   `App/Resources/InferenceTuning.json`. Editing the JSON did nothing.
3. **The corpus contains chunks far larger than any sane budget** — 17.7% exceed 512
   tokens, the largest is ~13,664.

The loop walks the relevance-ranked list. A single oversized chunk landing at rank 1
meant `0 + 700 > 600` on the first iteration → `break` → the model received **zero
chunks**, and the prompt said `[No relevant medical context found]`. The model then
answered a medical question from parametric memory, uncited — precisely the failure mode
this project exists to prevent.

## Measured, before

| | |
|---|---|
| chunks retrieved | 5.00 |
| chunks that reached the model | **1.52** (70% discarded) |
| queries receiving **zero** context | **47/209 = 22.5%** |
| doc-hit@5 of retrieval output | 0.7703 |
| doc-hit@5 **of what the model actually saw** | **0.4450** |

The system's real grounding rate was 0.445, not 0.77. This also explains an earlier
negative result: cross-encoder reranking moved nothing, because it was reordering chunks
that were being thrown away one step later.

## The fix

- `break` → `continue`, so an oversized chunk costs only itself.
- **Partial fill**: once a chunk does not fit whole, spend the remaining budget on its
  head rather than nothing — for a 13k-token passage, the first few hundred tokens of the
  right source beat silence. Guarded by `minimumUsefulChunkTokens = 80`, below which a
  fragment reads as authoritative while carrying no usable fact, and marked with `[…]` so
  the model does not treat the cut as the end of the guidance.
- **Wire the budget to `InferenceTuning`**, so the JSON knob is live and a sweep is a file
  edit, as `Docs/BE/inferenceTuning.md` always claimed.
- **Budget 600 → 2000.** 600 tokens is not a context window for a medical RAG system; the
  median chunk alone is 206 tokens.
- **`wordsToTokensRatio` 1.4 → 1.6.** Measured against real tokenised counts across all
  1238 chunks: median 1.554 tokens/word, mean 2.019, and 1.4 *under*-estimated 62.6% of
  chunks — the budget was being silently overshot by ~19% in aggregate.

## Measured, after

| config | chunks sent | ctx tokens | zero-context | doc-hit seen |
|---|---|---|---|---|
| before (`break`, 600, ratio 1.4, k=5) | 1.52 | 307 | 22.5% | 0.4450 |
| **after (`continue`+trim, 2000, ratio 1.6, k=5)** | **3.96** | 1720 | **0.0%** | **0.6890** |
| after, `top_k` = 10 | 4.95 | 1977 | 0.0% | 0.6890 |
| after, `top_k` = 10, budget 3000 | 6.40 | 2849 | 0.0% | 0.7512 |

**Grounding +55% relative, and no query reaches the model unsourced.**

### `top_k` alone does nothing

Raising `top_k` from 5 to 10 at budget 2000 changes doc-hit by **zero**: the budget binds
first, so the extra chunks are packed and then dropped. `top_k` is only worth raising
together with the budget — which is why it is a separate branch, gated on a latency
measurement, rather than folded in here.

## Cost

Context tokens per turn: 307 → 1720 (5.6x). Prefill is parallel on Apple Silicon and
cheap relative to decode, so this should be affordable against the 5s budget of success
criterion #3 — **but it is unmeasured**. Run `MobiCureVNTests/LatencyBenchmarkTests.swift`
(see `Docs/BE/Latency-Benchmark.md`) before and after this change on the iPad M5 and
report both numbers. If p95 regresses past budget, lower `contextTokenBudget` in the JSON
— it is now a live knob, and that is the whole point of wiring it.

## Root cause still open

The real defect is upstream: chunks of 13,664 tokens should not exist. The embedder window
is 512, so everything past that was never embedded — those chunks are only ever retrievable
by their opening. Splitting them at ingestion (`Pipeline/ingestion/chunk.py`) makes every
budget decision above cheaper and is tracked separately on `final/chunk-splitting`.
