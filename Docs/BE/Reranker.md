# On-device reranker: measured, shipped off

Branch `final0.1-reranker`. Adds a cross-encoder reranking step (`cross-encoder/ms-marco-MiniLM-L6-v2`,
converted to CoreML) to `SQLiteRetriever`, gated by `InferenceTuning.prompt.rerankCandidates`. The
knob ships at `0` (off): measured on the split index, the reranker traded doc-hit@k for recall@k
rather than improving both, so it is not a default win here.

## What it does when turned on

`SQLiteRetriever.retrieve` fetches `max(topK, rerankCandidates)` fused candidates instead of
`topK`, scores each `(query, passage)` pair with the cross-encoder, and keeps the best `topK` by
that score. A failed prediction or a missing `reranker.mlpackage`/`vocab.txt` falls back to the
fused RRF order — reranking never blocks retrieval. `Pipeline/eval/reranker.py` mirrors the same
step (`RerankingRetriever`) so the harness measures what the app would ship if the knob were on.

Files:
- `App/Backend/Services/RAG/CrossEncoderReranker.swift` — CoreML model, WordPiece pair encoding
  (`[CLS] query [SEP] passage [SEP]`, Hugging Face `longest_first` truncation), scoring.
- `Pipeline/tools/convert_reranker.py` — exports the reference model via `torch.export`, checks
  parity against the exported module and against `sentence_transformers.CrossEncoder` (what the
  harness scores with), writes `reranker.mlpackage` + `MobiCureVNTests/Fixtures/RerankerParity.json`.
- `Pipeline/eval/reranker.py`, `runner.py`'s `rerank_candidates`/`rerank_model` retrieval keys,
  `provenance.py`'s `reranker_bundled`/`rerank_candidates` (read from the bundled tuning file).
- Tests: `MobiCureVNTests/CrossEncoderRerankerTests.swift` (pair encoding + truncation rule vs. a
  live tokenizer probe, parity fixture, tie-break ordering), `Pipeline/eval/tests/test_reranker.py`
  (12: `RerankingRetriever`, `app_retrieval` reranker fields, shipped-config consistency, an
  end-to-end fts+rerank run with a fake scorer).

**Truncation rule.** Hugging Face's `longest_first` for a *pair* is not "drop one token at a time
from the longer side" (what a naive port assumes): a side no longer than half the room is kept
whole and the other takes the rest; when both sides are longer than half, the shorter side (the
query, on a tie) gets the floor of half and the longer side the remainder. Verified empirically
against `AutoTokenizer(query, passage, truncation="longest_first")` over thousands of length pairs
before trusting it in the Swift/Python mirrors.

## What was measured (and why it ships off)

Split index (1876 chunks, `sha256 398a1e9...`), 209 golden questions, CPU:

| k | candidates | recall@k | doc-hit@k | mrr | ndcg@k |
|---|---|---|---|---|---|
| 5 | 0 (off) | 0.2249 | **0.7799** | 0.1503 | 0.1689 |
| 5 | 10 | 0.2344 | 0.7608 | 0.1616 | 0.1795 |
| 5 | 20 | 0.2440 | 0.7560 | 0.1632 | 0.1832 |
| 5 | 30 | 0.2344 | 0.7368 | 0.1621 | 0.1801 |
| 5 | 50 | 0.2440 | 0.7464 | 0.1657 | 0.1852 |
| 10 | 0 (off) | 0.3110 | **0.8756** | 0.1674 | 0.2010 |
| 10 | 10 | 0.3110 | 0.8756 | 0.1717 | 0.2041 |
| 10 | 20 | 0.3206 | 0.8612 | 0.1732 | 0.2077 |
| 10 | 30 | 0.3110 | 0.8612 | 0.1718 | 0.2044 |
| 10 | 50 | 0.3110 | 0.8708 | 0.1739 | 0.2061 |

Every candidate depth raises recall@k and nDCG@k a little, but **lowers doc-hit@k** at k=5
(0.7799 → 0.7368–0.7608) and mostly at k=10 too (0.8756 → 0.8612–0.8708). Recall@k only credits
the exact gold *chunk*; doc-hit@k credits any chunk from the right *document*. Together these say
the cross-encoder is pulling the exact gold chunk slightly higher when it's already a candidate,
but it is also pushing OTHER chunks from the right document below chunks from a wrong document
more often than the reverse — a passage-relevance model reading a lone chunk without its
document's other context sometimes prefers the wrong document's most on-topic-sounding passage.
On a corpus mostly answered from within one document, that trade is a net loss for what patients
actually see (the sources panel, built from doc-hit territory, degrades more than the exact-chunk
metric improves).

Latency: 35.1 ms/pair on this laptop's CPU; 20 candidates ≈ 0.7 s added per query before the
device's Neural Engine, which this was never benchmarked on, is even considered.

MedCPT-Cross-Encoder (a biomedical reranker, plausibly a better fit for this corpus than a
general web-search model) was queued for the same sweep but not completed on this machine — the
CPU run did not finish in the session's time budget. `python -m eval.tools.rerank_sweep` (see the
sweep script referenced in the harness) or a rerun with `CrossEncoderReranker("ncbi/MedCPT-Cross-Encoder")`
is the natural next measurement before ruling reranking out for good.

## If a future measurement changes the trade-off

Set `rerankCandidates` in a device's `InferenceTuning.json` (Documents override, no rebuild) or
change the shipped default in `InferenceTuning.swift`/`App/Resources/InferenceTuning.json`
together. `Docs/Test-Protocol.md`'s eval gates should then require doc-hit@k not regressing versus
the no-rerank baseline, since that is exactly the metric this measurement caught moving the wrong
way.
