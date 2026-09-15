# Contextual header on chunk embeddings

Branch `final0.1-contextual-header`. Embeds `"<document title> › <section>"` above each chunk's
text — the embedding input only, never the stored text, FTS index, prompt, or UI. Shipped ON:
zero runtime cost (it is baked into the index at build time), and it measurably improves
retrieval. `App/Resources/vectorstore.db` now ships built this way.

## Why

A chunk is embedded on its own. "Empty it when it is a third full" carries no signal that it's
from a stoma-care leaflet rather than a diet page — the embedding has to place it near a query
purely on the chunk's own words. Prepending the title and section it came from is contextual
retrieval without an LLM rewrite: the header is metadata the corpus registry already has
(`Pipeline/data/registry.csv`).

## What changed

- `Pipeline/ingestion/contextual_header.py` — `embedding_text(chunk, titles)`: `titles=None`
  returns the chunk text unchanged (used for queries, and for a header-off index); otherwise
  returns `"<title> › <section>\n\n<text>"`, falling back gracefully when either part is missing.
- `Pipeline/ingestion/build_index.py`, `Pipeline/eval/index_builder.py` — both call
  `embedding_text` instead of embedding `chunk["text"]` directly, so the shipped index and the
  evaluated index embed identically.
- `Pipeline/ingestion/build_index.py --contextual-header` — new flag; `run_pipeline.sh`'s `index`
  stage now passes it, so a full pipeline run ships the header by default.
- `Pipeline/eval/build_indexes.py` — an experiment may set `embed: {"contextual_header": true}`
  (validated: no other per-experiment `embed` override is allowed, since queries are always
  embedded by the one shared model).
- `Pipeline/eval/experiment_config.json` — `neural_contextual` is now `represents_app: true`
  (App/Resources/vectorstore.db is built with the header); the old baseline is kept as
  `neural_no_header` for comparison; `neural_fts_only` points at the same (header) index in FTS
  mode, since the header changes nothing there.
- `Pipeline/eval/tests/test_contextual_header.py` (5 tests): header composition and fallbacks,
  that the embedder sees the header while the stored/FTS `text` column does not, and that the
  shipped config matches this decision.

**Only the embedding input changes.** `SQLiteRetriever`'s FTS pass, the prompt builder, and the
sources UI all read the `text` column, which is the chunk exactly as chunked — nothing downstream
of retrieval sees the header. A query is still embedded as typed; only passages carry it.

## Measured

Split index (1876 chunks, 39 docs), 209 golden questions, CPU, same hybrid retriever both ways:

| Index | recall@5 | doc-hit@5 | mrr | ndcg@5 |
|---|---|---|---|---|
| `neural_no_header` (old baseline) | 0.2249 | 0.7799 | 0.1503 | 0.1689 |
| `neural_contextual` (shipped) | **0.2297** | **0.8038** | 0.1463 | 0.1671 |

doc-hit@5 (any chunk from the right document) improves +2.4 points; recall@5 (the exact gold
chunk) improves +0.5 points. mrr and ndcg move a fraction of a point the other way — within the
noise of 209 questions, and outweighed by the doc-hit gain, which is what most golden questions'
answers actually depend on (the right document, not necessarily the one chunk the qrels happened
to pin). `neural_fts_only`, scored on the same index in FTS-only mode, is unchanged
(0.2010/0.7177) — expected, since FTS indexes the un-prefixed stored text.

Cost: none at query time (the header lives in the embeddings already on disk); a one-time
re-embedding of the corpus at ingestion (a few minutes on CPU for 1876 chunks).

## Rebuilding

```bash
cd Pipeline
python -m ingestion.build_index --force --contextual-header   # writes data/vectorstore.db
cp data/vectorstore.db ../App/Resources/vectorstore.db
python -m eval.build_indexes                                   # neural_contextual for eval
python -m eval.run_eval
```

## Tests

`python -m unittest eval.tests.test_contextual_header` (5, one skipped without
sqlite-vec/sentence-transformers): header text composition, missing-title/section fallbacks, the
header-off passthrough, that the index builder's embedder input carries the header while the
stored column does not (mocked model), and that the shipped config's `represents_app` experiment
is the one built with the header.
