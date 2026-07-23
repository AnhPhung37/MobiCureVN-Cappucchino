# MobiCureVN — RAG Pipeline & Retrieval Evaluation

> Last updated: 2026-07-24. Scope: the offline document-ingestion pipeline
> (`Pipeline/`), the on-device retrieval that ships in the app
> (`App/Backend/Services/RAG/`), and the golden-set evaluation harness
> (`Pipeline/eval/`). Line references point at the code at time of writing.

---

## 1. Overview

MobiCureVN answers colorectal-cancer / ostomy questions on-device using
Retrieval-Augmented Generation. Retrieval is **fully offline and on-device**:
there is no server. A curated corpus of clinical PDFs is processed ahead of time
into a single SQLite database (`vectorstore.db`) that ships inside the app
bundle. At query time the app searches that database locally and feeds the top
chunks to the LLM as grounding context, with citations.

```
                       OFFLINE (Pipeline/, run on a dev machine)
  raw PDFs ─▶ parse ─▶ clean ─▶ chunk ─▶ enrich ─▶ build index ─▶ vectorstore.db
                                                                        │
                                                    copied into the app bundle
                                                                        ▼
                       ON-DEVICE (App/, at query time)
  user question ─▶ SQLiteRetriever (FTS5 + vector KNN + RRF) ─▶ top-K chunks ─▶ LLM
```

Two things must stay in sync:
- **Embedding model** — the index and the app's query encoder must use the same
  model and dimensionality (`BAAI/bge-small-en-v1.5`, 384-dim). The app encodes
  queries with a CoreML conversion of that model
  (`App/Backend/Services/RAG/QueryEmbedder.swift`).
- **Schema** — `SQLiteRetriever` reads `chunks`, `vec_chunks`, and `chunks_fts`.
  The builder must create all three.

---

## 2. The corpus (`Pipeline/data/raw_pdfs/`, `registry.csv`)

The corpus is **39 documents** defined in `registry.csv`. Each row carries
metadata used downstream for filtering, citation, and confidence:

| field | example | use |
|---|---|---|
| `doc_id` | `NCCN_RCP_2026` | stable chunk-ID prefix (`NCCN_RCP_2026_c007`) |
| `source_org` | `NCCN`, `NHS`, `UOAA` | citation label |
| `doc_type` | `guideline`, `patient_education`, `research` | – |
| `credibility_tier` | `1` (clinical guideline) / `2` (patient ed.) | confidence boost |

Of the 39, **34 are auto-parsed from PDFs** in `data/raw_pdfs/`. The remaining
5 have no machine-parseable PDF (e.g. `Bowel_Cancer_UK_Colonic_Stenting`, which
`parse.py` lists in `_FAULTY_PDFS`) and are **hand-maintained** in the derived
directories. A full `--force` run regenerates the 34 and preserves the 5, so the
index always reflects the full registry.

---

## 3. The ingestion pipeline (`Pipeline/`)

Run all stages with:

```bash
cd Pipeline
source .venv/bin/activate          # so bare `python` resolves to the venv
./run_pipeline.sh --force          # parse → clean → chunk → enrich → index
```

Or invoke a single stage directly, e.g. `python ingestion/build_index.py --force`.
Every stage reads/writes under `Pipeline/data/` and skips work that already
exists unless `--force` is passed.

| # | Stage | Script | In → Out | Technique |
|---|---|---|---|---|
| 1 | Parse | `ingestion/parse.py` | `raw_pdfs/*.pdf` → `parsed_markdowns/*.md` | `pymupdf4llm` PDF→Markdown (preserves headings, lists, tables) |
| 2 | Clean | `ingestion/clean.py` | `parsed_markdowns/` → `cleaned_markdowns/` | strip boilerplate / artifacts, normalize whitespace |
| 3 | Chunk | `ingestion/chunk.py` | `cleaned_markdowns/` → `neural_chunks/` | **NeuralChunker** (default) or semantic (see §4) |
| 4 | Enrich | `ingestion/enrich_chunks.py` | `neural_chunks/` + `registry.csv` → `enriched_chunks/` | join registry metadata, extract section headings, assign `chunk_id` |
| 5 | Index | `ingestion/build_index.py` | `enriched_chunks/` → `vectorstore.db` | embed + build vec + FTS tables |

Output of the current run: **39 documents → 1238 chunks → `vectorstore.db` (6.6 MB)**.

### Deploying the index to the app

`SQLiteRetriever` loads `vectorstore.db` from the **app bundle**, i.e.
`App/Resources/vectorstore.db`. After rebuilding, copy it across:

```bash
cp Pipeline/data/vectorstore.db App/Resources/vectorstore.db
```

`App/Resources` is an Xcode *synchronized folder group*
(`PBXFileSystemSynchronizedRootGroup`), so any file placed there is bundled
automatically on the next build — no `project.pbxproj` edit needed. Keep backups
**outside** that folder or they will be shipped too.

---

## 4. Chunking techniques (`ingestion/chunk.py`)

Two strategies are implemented; **neural is the shipped default**.

**Neural (`--chunker neural`)** — `chonkie.NeuralChunker` with
`mirth/chonky_modernbert_base_1`. A ModernBERT model predicts semantic split
points, so boundaries fall at topic shifts rather than fixed token counts. There
is **no hard maximum chunk size**. Chunks below `MIN_CHUNK_TOKENS = 15` are
dropped.

**Semantic (`--chunker semantic`)** — a `chonkie` pipeline: markdown-aware
recursive splitting → `chunk_size=500` semantic grouping (similarity threshold
0.7) → 12% overlap refinement → embedding refinement with
`minishlab/potion-base-32M`. Because it caps at 500 tokens it fits the embedder
window cleanly (see the caveat below).

### Chunk-size caveat (known limitation)

The embedder `bge-small-en-v1.5` has a **512-token max sequence length**. The
neural chunker's size distribution on the current corpus:

```
min 15 · avg 401 · max 13,664 tokens
≥512 tokens: 219 / 1238 chunks (18%)
```

Chunks over 512 tokens (concentrated in table-heavy docs like
`NCCN_DPYD_2025`) are **truncated to their first ~512 tokens when embedded** — so
vector search only "sees" their opening. Mitigations already in place: the full
chunk text is still stored and returned to the LLM (truncation affects the
*embedding* only), and the FTS5 keyword index covers the full text. To remove
the caveat, either run `--chunker semantic` (500-token cap) or add a
split-oversized-chunks step to the neural path.

---

## 5. Embedding & index build (`ingestion/build_index.py`)

- **Model:** `BAAI/bge-small-en-v1.5`, 384-dim, L2-normalized (cosine via dot).
- **`chunks`** — metadata table (`chunk_id`, `doc_id`, `text`, `token_count`,
  `section`, `page_start`, `doc_type`, `source_org`, `credibility_tier`).
- **`vec_chunks`** — `sqlite-vec` virtual table, `embedding float[384]`, KNN.
- **`chunks_fts`** — FTS5 virtual table over `text`, `tokenize='porter ascii'`,
  for BM25 keyword search.

All three tables are required by the app. (An earlier version of the *eval*
builder omitted `chunks_fts`; see §7.)

---

## 6. On-device retrieval (`App/Backend/Services/RAG/SQLiteRetriever.swift`)

Hybrid retrieval over the bundled DB:

1. **FTS5 / BM25** — the question is tokenized (alphanumeric, ≥3 chars,
   stopwords removed), each token gets a `*` prefix wildcard, and they are
   **OR-joined** (ANDing a natural-language question over-constrains and matches
   nothing). Returns up to `candidateLimit = max(topK*3, topK)` rows.
2. **Vector KNN** — the query is embedded on-device (`QueryEmbedder`, CoreML
   BGE-small) and matched against `vec_chunks`.
3. **Fusion** — the two result lists are merged with **Reciprocal Rank Fusion**
   (`k=60`), deduped by a content fingerprint (first 200 normalized chars), and
   truncated to `topK` (default 5).
4. **Confidence** — combines top/avg relevance, document diversity, and a
   credibility-tier boost; surfaced to the UI alongside citations.

If the vector index or embedder is unavailable, retrieval degrades gracefully to
FTS-only (and to a `LIKE` fallback if even FTS is missing).

### Retrieval tuning (2026-07-24)

Evaluation (§7) showed the original config was **FTS-dominated**: the broad
OR-of-terms query saturated the candidate budget on 100% of golden queries, and
the old "skip the vector pass when FTS is full" rule meant the vector signal was
**never used** — leaving hybrid *worse* than pure vector. Two changes were made:

- **Always fuse the vector pass** (removed the skip-when-FTS-full shortcut).
- **Drop common stopwords** from the FTS query (`ftsStopwords`) to sharpen BM25.

Cost: one on-device embedding per query (previously skipped for latency). For a
medical RAG app the retrieval gain is judged worth it; a middle ground (skip
vector only when FTS's top BM25 score is strong) remains open.

---

## 7. Retrieval evaluation (`Pipeline/eval/`)

An offline information-retrieval benchmark: *for a set of known questions, does
retrieval return the chunks a human marked correct?* Driven by
`experiment_config.json`.

### Dataset
- `eval/data/queries.jsonl` — natural-language questions (+ reference answers).
- `eval/data/qrels.jsonl` — the answer key: relevant `chunk_id`s per query.

Because re-chunking shifts chunk boundaries, `chunk_id`s in the qrels can go
stale. `tools/remap_qrels.py` repairs them: it recovers each stale chunk's
original text from the previous index and maps it to the best-matching new chunk
in the same document (cosine ≥ 0.80 **or** token-containment ≥ 0.75), dropping
IDs (and any queries thereby emptied) that have no clean single-chunk
equivalent. Current set after cleanup: **209 aligned queries, 0 broken
references.**

### Metrics (`eval/metrics_ir.py`)
- **recall@5** — fraction of relevant chunks found in the top 5 (primary).
- **MRR** — 1/rank of the first relevant hit (ranking quality).
- **nDCG@5** — position-weighted recall, normalized to the ideal ordering.
- **doc-hit@5** (reported by the A/B tool) — did any top-5 chunk come from the
  right *document*. More robust than exact-chunk recall, which is deflated when
  the retriever returns an equally-correct *neighbor* chunk after re-chunking.

The retriever in the eval (`eval/retriever.py::HybridRetriever`) is a **faithful
port of the app's Swift retriever**, so scores reflect what ships. Query
enrichment (the app's `enrichedTerms`) is not modelled.

### Running it
```bash
cd Pipeline
python -m eval.build_indexes    # enrich + build eval/outputs/*.db (mirrors the shipped index, incl. FTS)
python -m eval.run_eval         # writes eval/results/eval_<timestamp>.json
python -m tools.ab_retrieval    # A/B sweep of retrieval variants (table below)
```

### Results (209 queries, top_k=5)

| variant | recall@5 | mrr | ndcg@5 | doc-hit@5 |
|---|---|---|---|---|
| vector-only | 0.239 | **0.170** | **0.187** | 0.756 |
| hybrid (original ship) | 0.187 | 0.097 | 0.119 | 0.689 |
| hybrid + always_fuse | 0.249 | 0.147 | 0.172 | 0.766 |
| hybrid + drop_stopwords | 0.220 | 0.130 | 0.153 | 0.708 |
| **hybrid + fuse + stopwords (now shipped)** | **0.249** | 0.159 | 0.181 | **0.770** |
| hybrid + fuse + stop + min_tok=5 | 0.249 | 0.152 | 0.176 | 0.761 |

**Findings**
- The original hybrid config was the weakest — vector was never consulted.
- `always_fuse` recovers the whole gap (recall 0.187→0.249, doc-hit 0.689→0.766);
  `drop_stopwords` adds ranking quality on top. This pair is now shipped (§6).
- Pure vector still edges out on MRR/nDCG (ranks the single gold chunk at #1 more
  often); the fused config wins recall/doc-hit, which matters more when feeding
  5 chunks to the LLM.
- Absolute recall@5 (~0.25) looks low because most queries have a single labelled
  gold chunk and re-chunking makes the retriever return a correct *neighbor*;
  **doc-hit@5 ≈ 0.77** is the more trustworthy signal of usefulness.

---

## 8. Reproducing the full flow

```bash
# 0. Environment (once)
cd Pipeline && python -m venv .venv && .venv/bin/pip install -r requirements.txt

# 1. Rebuild the index from the current PDFs
source .venv/bin/activate
./run_pipeline.sh --force

# 2. Sanity-check retrieval against the new index
python tools/smoke_retrieve.py "What is DPYD testing and why does it matter?"

# 3. Deploy to the app bundle
cp data/vectorstore.db ../App/Resources/vectorstore.db

# 4. Evaluate (optional but recommended after any chunking/retrieval change)
python tools/remap_qrels.py --apply     # only if chunk IDs shifted
python -m eval.build_indexes
python -m eval.run_eval
python -m tools.ab_retrieval
```

---

## 9. Key files

| Path | Role |
|---|---|
| `Pipeline/run_pipeline.sh` | orchestrates the 5 ingestion stages |
| `Pipeline/ingestion/*.py` | per-stage scripts (parse/clean/chunk/enrich/index) |
| `Pipeline/registry.csv`, `data/registry.csv` | 39-doc corpus manifest + metadata |
| `Pipeline/data/vectorstore.db` | built index (source of truth) |
| `App/Resources/vectorstore.db` | index shipped in the app bundle |
| `App/Backend/Services/RAG/SQLiteRetriever.swift` | on-device hybrid retrieval |
| `App/Backend/Services/RAG/QueryEmbedder.swift` | CoreML BGE-small query encoder |
| `Pipeline/eval/` | golden-set IR evaluation harness |
| `Pipeline/tools/smoke_retrieve.py` | quick ad-hoc retrieval check |
| `Pipeline/tools/remap_qrels.py` | repair stale qrel chunk IDs after re-chunking |
| `Pipeline/tools/ab_retrieval.py` | A/B sweep of retrieval variants |

---

## 10. Open items

- **Oversized chunks (§4):** 18% of chunks exceed the 512-token embedder window.
  Adopt semantic chunking or split oversized neural chunks.
- **Vector-pass latency (§6):** `always_fuse` embeds every query on-device;
  measure real-device latency and consider a BM25-confidence gate if needed.
- **Eval coverage:** qrels mostly label a single gold chunk per query; adding
  multi-chunk relevance and modelling query enrichment would tighten the metrics.
- **Semantic-chunker eval:** the eval currently runs the neural experiment only;
  re-add a semantic experiment to compare chunking strategies head-to-head.
