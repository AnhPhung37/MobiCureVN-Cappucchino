# The context budget was discarding 70% of retrieval

_Measured 2026-09-13 over the 209-query golden set, 1238 chunks / 39 docs, hybrid retriever
(FTS + vector, as shipped once the query embedder is bundled), CPU._

Retrieval was never the bottleneck. The bottleneck sat between retrieval and the model.

---

## What was happening

1. **`applyContextBudget` used `break`, not `continue`** — on the first chunk too large to fit,
   every chunk behind it was discarded, however small.
2. **The budget was 600 tokens, and a dead knob** — `MedicalChatOrchestrator` read a hardcoded
   `600` while `InferenceTuning.Prompt.contextTokenBudget` was parsed from the JSON and ignored.
3. **The corpus contains chunks far larger than any sane budget** — 17.7% exceed 512 tokens, the
   largest is ~13,664.

A single oversized chunk at rank 1 therefore emptied the context, and the prompt said
`[No relevant medical context found]`: the model answered a medical question from parametric
memory, uncited — precisely the failure this project exists to prevent.

## Measured, before

| | |
|---|---|
| chunks retrieved | 5.00 |
| chunks that reached the model | **1.52** (70% discarded) |
| queries receiving **zero** context | **47/209 = 22.5%** |
| doc-hit@5 of retrieval output | 0.7703 |
| doc-hit@5 **of what the model actually saw** | **0.4450** |

## The fix

**Packing, in two passes** (`applyContextBudget(_:budget:ratio:)`):

1. every chunk that fits whole, in rank order — one that does not fit is skipped and costs only
   itself;
2. the remaining budget, if at least 80 tokens, goes to the head of the highest-ranked chunk that
   was skipped, kept at its own rank and marked `[…]`.

The first version of this fix did the partial fill *during* the scan and then stopped, so a huge
chunk at rank 1 still consumed the whole budget and evicted every small chunk behind it. Its cut
also split on `" "` while the estimate counted all whitespace, so a passage with line breaks could
come back uncut and over budget. The head is now cut in the original string at the word the
estimate counts to, keeping line breaks, and the marker is paid for: **the packed context never
exceeds the budget, which also makes packing idempotent** (property test over 300 random cases).

**Sources follow the packing.** `processQuery` packs first and hands the packed context to the
prompt's Sources list, to the citation cards (`onSourcesRetrieved`) and to the output guardrail.
Before, all three saw every retrieved document, so the model was shown sources whose passages it
never received, and the patient could see a citation the answer could not have used.

**The budget is live and 2000.** It reads `InferenceTuning`; 600 is not a context window for a
medical RAG system when the median chunk alone is ~206 tokens.

**Tokens per word are measured per model, with the model's tokenizer.** The estimate is
`whitespace words × ratio`, and the budget exists to bound prefill on the *chat* model. The value
first shipped here (1.6) came from the retrieval embedder's WordPiece tokenizer. Measured with each
shipped model's own `tokenizer.json` (`Pipeline/tools/measure_token_ratio.py`), as a chunk is
formatted into the prompt, aggregated over the corpus:

| Model | EN tokens/word | VI tokens/word (24 texts) | `ModelCatalog.wordsToTokensRatio` |
|---|---|---|---|
| Qwen 3.5 4B (default) | 1.715 | 1.114 | **1.75** |
| Qwen 2.5 3B / VL 3B / VL 7B | 1.684 | 1.270 | 1.70 |
| Llama 3.2 3B | 1.606 | 1.228 | 1.65 |
| Phi 3.5 mini | 2.039 | 2.826 | 2.85 |
| Gemma 3 1B | 1.689 | 1.204 | 1.70 |

Each model's ratio is the ceiling over both languages the budgets meter (English context; English
or Vietnamese history), rounded up to 0.05. One global value would have overshot the budget on Phi
by 20% or starved Qwen's context. `InferenceTuning.prompt.wordsToTokensRatio` is now an optional
override for sweeps; `null` ships. The Vietnamese sample is small (the 12 paired questions); treat
those figures as indicative.

**The tuning file can no longer freeze old defaults.** The Documents copy was seeded with every
value on first launch and then always won, so on any device that had run the app once, the bundled
2000 was ignored and 600 kept running. Resolution is now layered — built-in defaults ← bundled JSON
← Documents JSON, key by key — and a Documents file that is still an untouched seed (its values
match the fingerprint written into it) is not a layer: it is rewritten with the live values. An
edited file still overrides, which is what the "knob is live" check relies on.
`InferenceTuningResolutionTests` pins the layering and that the bundled JSON equals the compiled
defaults.

## Measured, after

`python -m tools.simulate_context_packing` (on `final/multilang-embedder-and-test-protocol`), which
mirrors the Swift packer:

| config | chunks sent | est. ctx tokens | zero-context | doc-hit seen |
|---|---|---|---|---|
| before (`break`, 600, ratio 1.4, k=5) | 1.52 | 307 | 22.5% | 0.4450 |
| **after (two-pass, 2000, ratio 1.75, k=5)** | **4.51** | 1764 | **0.0%** | **0.7416** |
| after, k=10, 2000 | 6.20 | 1975 | 0.0% | 0.7512 |
| after, k=10, 2500 | 6.90 | 2441 | 0.0% | 0.7656 |
| after, k=10, 3000 | 7.50 | 2875 | 0.0% | 0.8134 |

**Grounding +67% relative at the same k, and no query reaches the model unsourced.** Raising `top_k`
is a separate, latency-gated decision on `final/retrieval-topk`.

## Cost

Estimated context tokens per turn: 307 → 1764 (5.7×). Prefill is parallel on Apple Silicon and cheap
relative to decode, so this should be affordable against the 5 s budget of success criterion #3 —
**but it is unmeasured**. Run `MobiCureVNTests/LatencyBenchmarkTests.swift` before and after on the
iPad M5. If p95 regresses past budget, lower `contextTokenBudget` in the Documents copy and
re-measure.

## Root cause still open

Chunks of 13,664 tokens should not exist: the embedder window is 512, so everything past that was
never embedded. Splitting them at ingestion is `final/chunk-splitting`.
