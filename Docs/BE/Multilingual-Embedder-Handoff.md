# Handoff: multilingual retrieval embedder

**Branch:** `final/multilang-embedder-and-test-protocol`, based on **`final/eval-integrity`** (not `main`)
**Status:** investigation only — no app code changed, no decision taken
**Written:** 2026-09-12 · **For:** a Claude Code session on the Mac Studio M3 Max

The base matters: `tools/compare_embedders.py` imports `doc_hit_at_k` / `doc_id_of` from
`eval/metrics_ir.py`, which exist only on `final/eval-integrity`, and the comparison is
only meaningful against that branch's corrected harness (the harness on `main` scores a
retriever configuration the app no longer uses; see `Docs/Eval-Integrity-Finding.md`). Checking this branch out
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
   pass via RRF — and until `final/eval-integrity` bundled the CoreML query embedder, no build
   of the app ran the vector pass at all. These numbers isolate the embedder; they are comparable to *each other*
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

**If `final/chunk-splitting` has been merged**, the corpus is 1876 chunks, not 1238, and
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

## 5. The Swift tokenizer — smaller than it looked

`App/Backend/Services/RAG/WordPieceTokenizer.swift` implements **WordPiece** from a BERT-style
`vocab.txt`. Both multilingual candidates here (and `google/embeddinggemma-300m`,
`Qwen/Qwen3-Embedding-0.6B`) use other algorithms — SentencePiece/Unigram or BPE — so the Swift
tokenizer cannot be reused for them.

An earlier version of this section concluded that a swap needs a SentencePiece tokenizer written
in Swift. It does not: the project already links **swift-transformers 1.3.3** (the `Tokenizers`
product, used by the MLX packages), whose `AutoTokenizer.from(modelFolder:)` loads a model's
`tokenizer.json` and maps `XLMRobertaTokenizer` to its Unigram implementation and
`GemmaTokenizer` to BPE. The work is therefore:

1. bundle the candidate's `tokenizer.json` (and config) beside its CoreML model;
2. tokenize queries with `Tokenizers` instead of `WordPieceTokenizer`;
3. **prove parity before trusting it** — a tokenizer that disagrees with Python does not fail, it
   returns embeddings that are merely bad. Export a fixture from the converter exactly as
   `Pipeline/tools/convert_embedder.py` does for bge-small (`MobiCureVNTests/Fixtures/QueryEmbedderParity.json`)
   and extend `QueryEmbedderParityTests` to the new model. The bge-small parity work found that
   the obvious implementation got accent stripping, symbol splitting and CJK handling wrong; assume
   a new tokenizer path does too until the fixture says otherwise.

Option (c) — a multilingual model that keeps a WordPiece vocabulary — still avoids step 2, but it
is no longer the only route that fits a week.

## 6. Every place the embedder identity is declared

All of these must agree, or retrieval fails in ways that look like bad relevance rather
than a configuration error.

| File | What to change |
|---|---|
| `Pipeline/ingestion/build_index.py:59-60` | `EMBED_MODEL`, `EMBED_DIM` |
| `Pipeline/eval/experiment_config.json:4-5` | `embed.model_name`, `embed.embed_dim` |
| `Pipeline/ingestion/build_index.py:109` | `vec0(embedding float[dim])` — follows `EMBED_DIM` |
| `Pipeline/eval/index_builder.py:76` | same, for the eval index |
| `Pipeline/tools/convert_embedder.py` | `--model`; pooling is read from the model's SentenceTransformer config, and the converter refuses to export a model that disagrees with it |
| `App/Backend/Services/RAG/QueryEmbedder.swift:17` | `embedDim` (384) |
| `App/Backend/Services/RAG/QueryEmbedder.swift:16` | `maxSeqLen` (128) |
| `App/Backend/Services/RAG/WordPieceTokenizer.swift` | replaced by a swift-transformers tokenizer for a non-WordPiece model (§5) |
| bundled resources | `App/Resources/query_embedder.mlpackage`, `App/Resources/vocab.txt` and `MobiCureVNTests/Fixtures/QueryEmbedderParity.json` — all re-exported together |

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

## 9. Follow-up: `final0.1-embedder-candidates`

Picks up exactly this handoff's open question with `tools/compare_embedders.py --candidates`,
comparing the shipped `BAAI/bge-small-en-v1.5` against two models that did not exist when §2's
numbers were measured: `Qwen/Qwen3-Embedding-0.6B` (prompts wired from its
`config_sentence_transformers.json`) and `google/embeddinggemma-300m` (gated on Hugging Face —
accept its licence and log in before running).

**Status: local patch, uncommitted, not run to completion.** It was written on the same Linux
machine this handoff warns against using — no GPU headroom for a 0.6B embedding model over 1876
chunks in a reasonable time, so the run was never finished and the patch was never committed to
`final0.1-embedder-candidates`. Do the actual comparison on the Mac Studio, following every "Do
not" in §7 above, before that branch is worth merging. Full `final0.1-*` merge order and
prerequisites: `Docs/Test-Protocol.md` §7.
