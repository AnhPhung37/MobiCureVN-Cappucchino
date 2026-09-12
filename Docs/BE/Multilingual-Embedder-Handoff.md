# Handoff: multilingual retrieval embedder

**Branch:** `final/multilang-embedder-and-test-protocol`, based on **`final/eval-integrity`** (not `main`)
**Status:** investigation only — no app code changed, no decision taken
**Written:** 2026-09-12 · **For:** a Claude Code session on the Mac Studio M3 Max

The base matters: `tools/compare_embedders.py` imports `doc_hit_at_k` / `doc_id_of` from
`eval/metrics_ir.py`, which exist only on `final/eval-integrity`, and the comparison is
only meaningful against that branch's corrected corpus config (the harness on `main`
scores a 9-document index against a 39-document answer key). Checking this branch out
gives you both.

> **Read this before running anything.** The experiment was started on a laptop, pulled
> ~6 GB of weights, OOM'd a 6 GB GPU because the device was not pinned, and was killed
> mid-run. Nothing here is urgent enough to repeat that. Run it on the Mac Studio, pin
> the device, and expect it to take a while.

---

## 1. The question

The corpus is **100% English** (39/39 documents). The app answers in Vietnamese by
translating VI→EN before retrieval (`ChatService` → `MedicalChatOrchestrator`, which
documents that `userQuery` is "always English by this point").

Would a multilingual embedder let a Vietnamese query retrieve from the English corpus
*directly*, removing that translation hop — and what does it cost in English accuracy?

This also touches **success criterion #4** (Vietnamese proficiency): citations currently
surface to the patient in English because the corpus is English.

## 2. What is already measured

Vector-only retrieval (pure dense, **not** the shipped hybrid FTS+vec+RRF), over the
**1238-chunk** corpus, 209 EN golden queries + 12 paired VI/EN questions.

| model | EN doc-hit@5 | EN recall@5 | VI chunk-overlap@5 | VI same-doc@5 | cos(VI,EN query) |
|---|---|---|---|---|---|
| `BAAI/bge-small-en-v1.5` (shipped) | **0.7560** | 0.2392 | **0.000** | 0.583 | **0.403** |
| `intfloat/multilingual-e5-small` ⚠️ | 0.7177 | 0.2153 | 0.167 | 0.750 | **0.856** |
| `BAAI/bge-m3` | — | — | — | — | — |

**The one conclusion that is safe to quote:** with the shipped embedder, a Vietnamese
query retrieves **zero** of the same chunks its English translation retrieves, and the
VI/EN query vectors sit at cosine 0.403 — barely related. **The translation round-trip
is load-bearing and cannot be dropped without changing the embedder.** That alone is
enough for a "future work" slide.

### Three caveats, all of which matter

1. ⚠️ **The e5 row is under-reported.** The e5 family is trained with mandatory
   `"query: "` / `"passage: "` prefixes and loses real accuracy without them. That run
   omitted them. The corrected re-run was the job that got killed. **Do not quote the
   e5 English numbers.** `tools/compare_embedders.py` now applies the prefixes.
2. **bge-m3 has no result at all.** First attempt OOM'd on CUDA; the CPU re-run was
   killed before it finished. It is the strongest multilingual candidate and the most
   likely to change the recommendation.
3. **Vector-only, not hybrid.** The shipped retriever fuses FTS5/BM25 with the vector
   pass via RRF. These numbers isolate the embedder; they are comparable to *each other*
   but not directly to the hybrid figure of doc-hit@5 = 0.7703 in
   `Docs/Eval-Integrity-Finding.md`.

## 3. Run it

```bash
# On the Mac Studio.
git checkout final/multilang-embedder-and-test-protocol   # already includes final/eval-integrity
cd Pipeline
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt sentence-transformers

# The comparison reads enriched chunks, so build them once:
python -m eval.build_indexes

# The Vietnamese query set lives on another branch:
git show final/answer-quality:Pipeline/eval/data/queries_vi.jsonl > eval/data/queries_vi.jsonl

# Apple Silicon: --device mps. Never leave the device unpinned.
python -m tools.compare_embedders --device mps \
    --out ../Docs/audits/embedder-comparison.json

# Optional: does bge's documented retrieval instruction help? The pipeline does not use it.
python -m tools.compare_embedders --device mps --models BAAI/bge-small-en-v1.5 --bge-instruction
```

**If `final/chunk-splitting` has been merged**, the corpus is 2108 chunks, not 1238, and
none of the numbers in §2 are comparable any more. Re-measure the baseline in the same
run rather than against this table.

## 4. Decision criteria

Recommend a swap only if **both** hold:

- **Cross-lingual works:** VI same-doc@5 ≥ ~0.85 and cos(VI,EN query) ≥ ~0.85. Below
  that, the translation hop is still doing the work and the swap buys nothing.
- **English does not regress materially:** EN doc-hit@5 within ~2 points of 0.7560.
  The English path is what every current measurement and the whole golden set rests on.

If cross-lingual works but English regresses, that is a genuine trade-off to *report*,
not to silently take — write it up rather than deciding alone.

## 5. The real blocker is the Swift tokenizer, not the model

This is the part that makes the swap a week of work rather than an afternoon, and it is
easy to miss until the CoreML export is already done.

`App/Backend/Services/RAG/WordPieceTokenizer.swift` implements **WordPiece** and reads a
BERT-style `vocab.txt` (one token per line, index = id). Both multilingual candidates use
**SentencePiece / XLM-RoBERTa**, which is a different algorithm with a different vocab
format. `vocab.txt` does not exist for them in the form the Swift code expects.

So a swap requires one of:

- **(a)** Write a SentencePiece tokenizer in Swift (unigram model, byte-fallback). Real
  work, and a wrong implementation fails *silently* — it returns embeddings that are
  merely bad, not an error.
- **(b)** Bundle the tokenizer inside the CoreML model so Swift passes a string rather
  than token ids. Cleanest if `coremltools` can express it for this model.
- **(c)** Use a multilingual model that keeps a WordPiece vocabulary (e.g. a distilled
  mBERT-based retriever). Weaker models, but no Swift work at all. **Evaluate this option
  before committing to (a)** — it may be good enough and it is the only route that fits a
  week.

## 6. Every place the embedder identity is declared

All of these must agree, or retrieval fails in ways that look like bad relevance rather
than a configuration error.

| File | What to change |
|---|---|
| `Pipeline/ingestion/build_index.py:59-60` | `EMBED_MODEL`, `EMBED_DIM` |
| `Pipeline/eval/experiment_config.json:4-5` | `embed.model_name`, `embed.embed_dim` |
| `Pipeline/ingestion/build_index.py:109` | `vec0(embedding float[dim])` — follows `EMBED_DIM` |
| `Pipeline/eval/index_builder.py:76` | same, for the eval index |
| `Pipeline/tools/convert_embedder.py:22` | `MODEL_ID`; also the hardcoded `assert out.shape == (1, 384)` |
| `App/Backend/Services/RAG/QueryEmbedder.swift:17` | `embedDim` (384) |
| `App/Backend/Services/RAG/QueryEmbedder.swift:16` | `maxSeqLen` (128) |
| `App/Backend/Services/RAG/WordPieceTokenizer.swift` | the blocker in §5 |
| bundled resources | `query_embedder.mlpackage`, `vocab.txt` — both re-exported |

`App/Resources/vectorstore.db` must be rebuilt and re-copied; an index built with one
embedder and queried with another returns confident nonsense, with no error anywhere.

## 7. Do not

- **Do not run this on a laptop.** Several GB of weights and sustained all-core
  inference. That is what prompted this handoff.
- **Do not leave the device unpinned.** PyTorch will take CUDA and OOM on a small card.
- **Do not quote the e5 English numbers in §2** — they are missing the required prefixes.
- **Do not change the embedder without rebuilding both indexes** (`Pipeline/` and
  `App/Resources/`) in the same change.
- **Do not merge this before `final/context-budget-fix`.** That branch is a confirmed
  +55% grounding fix with no hardware dependency; this one is speculative. Ship the sure
  thing first.

## 8. Realistic verdict for the capstone

**This does not fit in the week before the presentation.** The measurement is worth
finishing — the bge-m3 row in particular — because "we measured cross-lingual retrieval
and here is why we kept the translation hop" is a strong slide. The *swap* is future
work, gated on §5.
