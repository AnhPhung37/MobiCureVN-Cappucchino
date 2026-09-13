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
  raw PDFs ─▶ parse ─▶ clean ─▶ chunk ─▶ split ─▶ enrich ─▶ build index ─▶ vectorstore.db
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
  (`App/Backend/Services/RAG/QueryEmbedder.swift`), bundled as
  `App/Resources/query_embedder.mlpackage` + `vocab.txt` since `final/eval-integrity` — before that
  no build contained it and retrieval ran FTS-only. It must use the model's own **[CLS] pooling**;
  regenerate it with `python -m tools.convert_embedder`, which refuses to export a model that
  disagrees with `SentenceTransformer`, and check it on device with `QueryEmbedderParityTests`.
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
./run_pipeline.sh --force          # parse → clean → chunk → split → enrich → index
```

Or invoke a single stage directly, e.g. `python ingestion/build_index.py --force`.
Every stage reads/writes under `Pipeline/data/` and skips work that already
exists unless `--force` is passed.

| # | Stage | Script | In → Out | Technique |
|---|---|---|---|---|
| 1 | Parse | `ingestion/parse.py` | `raw_pdfs/*.pdf` → `parsed_markdowns/*.md` | `pymupdf4llm` PDF→Markdown (preserves headings, lists, tables) |
| 2 | Clean | `ingestion/clean.py` | `parsed_markdowns/` → `cleaned_markdowns/` | strip boilerplate / artifacts, normalize whitespace |
| 3 | Chunk | `ingestion/chunk.py` | `cleaned_markdowns/` → `neural_chunks/` | **NeuralChunker** (default) or semantic (see §4) |
| 3b | Split | `ingestion/split_oversized.py` | `neural_chunks/` in place | pieces over 480 tokens split at paragraph / sentence / word boundaries, text kept verbatim; records `source_chunk_index` (see §4) |
| 4 | Enrich | `ingestion/enrich_chunks.py` | `neural_chunks/` + `registry.csv` → `enriched_chunks/` | join registry metadata, extract section headings, assign `chunk_id` |
| 5 | Index | `ingestion/build_index.py` | `enriched_chunks/` → `vectorstore.db` | embed + build vec + FTS tables |

Output of the current run: **39 documents → 1876 chunks** (1238 before the split stage) **→ `vectorstore.db`**.

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

### Chunk size and the embedder window

The embedder `bge-small-en-v1.5` has a **512-token max sequence length**. The
neural chunker has no maximum, and on this corpus produced:

```
min 15 · avg 401 · max 13,664 tokens
≥512 tokens: 219 / 1238 chunks (18%)
```

Everything past a chunk's first 512 tokens was never embedded. `final/chunk-splitting`
adds stage 3b (`ingestion/split_oversized.py`): chunks over 480 tokens are cut at
paragraph, then sentence, then word boundaries into slices of the original text, with at
most 48 tokens of overlap. Result: **1876 chunks, max 480 tokens**. Each piece records
`source_chunk_index`, so the golden set is remapped exactly (§7).

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
   truncated to `topK` — `InferenceTuning.prompt.retrievalTopK`, 10 with
   `final/retrieval-topk` (5 before).
4. **Confidence** — combines top/avg relevance, document diversity, and a
   credibility-tier boost; surfaced to the UI alongside citations.

If the vector index or embedder is unavailable, retrieval degrades to FTS-only (and to a
`LIKE` fallback if even FTS is missing) and logs that it did — which is what every build ran
until the embedder was bundled.

Retrieved chunks are then packed into `contextTokenBudget` (3000 estimated tokens with
`final/retrieval-topk`) by the two-pass packer in `MedicalChatOrchestrator`, and the prompt's
source list, the citation cards and the output guardrail see only the packed chunks — see
`Docs/BE/Context-Budget-Finding.md`.

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
stale. `tools/remap_qrels.py` repairs them in one of two ways:

- `--from-split-provenance` (after the split stage) — exact: each gold chunk maps to all of its
  pieces, written as one `relevant_groups` entry. `eval.metrics_ir` counts a group as found when
  any piece is retrieved, so a split gold chunk is still one label.
- `--old-db OLD --new-db NEW` (after re-chunking from Markdown) — approximate: the most similar
  chunk in the same document (cosine ≥ 0.80 **or** token containment ≥ 0.75); weaker matches are
  dropped and listed.

Current set: **209 queries, 0 broken references**; on the split corpus 51 gold chunks are groups
of 2–11 pieces.

### Metrics (`eval/metrics_ir.py`)
- **recall@5** — fraction of relevant chunks found in the top 5 (primary).
- **MRR** — 1/rank of the first relevant hit (ranking quality).
- **nDCG@5** — position-weighted recall, normalized to the ideal ordering.
- **doc-hit@5** — did any top-5 chunk come from the right *document*. More robust
  than exact-chunk recall, which is deflated when the retriever returns an
  equally-correct *neighbor* chunk after re-chunking. It is computed by the harness
  itself (`metrics_ir.py::doc_hit_at_k`) and written into every result JSON —
  previously it existed only in an untracked side tool, which made it a number the
  docs quoted but no artifact could confirm.

The retriever in the eval (`eval/retriever.py::HybridRetriever`) is a **faithful
port of the app's Swift retriever**, so scores reflect what ships — provided `App/Resources`
bundles the query embedder; without it the app searches FTS-only (`Docs/Eval-Integrity-Finding.md`). Query
enrichment (the app's `enrichedTerms`) is not modelled.

### Running it
```bash
cd Pipeline
python -m eval.build_indexes    # enrich + build eval/outputs/*.db (mirrors the shipped index, incl. FTS)
python -m eval.run_eval         # writes eval/results/eval_<timestamp>.json
python -m tools.ab_retrieval    # A/B sweep of retrieval variants (table below)
```

### Results (209 queries, top_k=5)

> **Read before quoting (corrected 2026-09-13).** These rows were measured with
> `tools/ab_retrieval.py` on the full 39-document index — the committed July results retrieve
> from 38–39 documents; an earlier note here claiming a 9-document index was wrong. Two things
> limit them: the row labelled "hybrid (ships)" is the app's *old* rule (the app now always fuses
> and drops stopwords, the "+fuse +stopwords" row), and until `final/eval-integrity` no build
> shipped the vector half at all — the app searched FTS-only (recall@5 0.2201, doc-hit@5 0.7081).
> Current numbers, with provenance: `Docs/Eval-Integrity-Finding.md`.

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
- Absolute recall@5 (~0.25) is low largely because 207 of 209 queries label a
  single gold chunk, so an equally correct neighbour scores zero; doc-hit@5 (≈0.77)
  is the companion metric. An earlier edit here blamed missing gold chunks in the
  index — that was wrong (see `Docs/Eval-Integrity-Finding.md`).

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
#    run_pipeline.sh's index stage (ingestion/build_index.py) writes data/vectorstore.db;
#    App/Resources/ is what ships.
cp data/vectorstore.db ../App/Resources/vectorstore.db

# 4. Evaluate (optional but recommended after any chunking/retrieval change)
python -m tools.remap_qrels --from-split-provenance --apply   # after a split
# python -m tools.remap_qrels --old-db OLD.db --new-db data/vectorstore.db --apply   # after re-chunking
python -m eval.build_indexes
python -m eval.run_eval
python -m tools.ab_retrieval
```

---

## 9. Key files

| Path | Role |
|---|---|
| `Pipeline/run_pipeline.sh` | orchestrates the 6 ingestion stages |
| `Pipeline/ingestion/*.py` | per-stage scripts (parse/clean/chunk/split/enrich/index) |
| `Pipeline/run_pipeline.py` | legacy single-file pipeline over the 9-document top-level folders; not the one to run |
| `Pipeline/data/registry.csv` | 39-doc corpus manifest + metadata (`Pipeline/registry.csv` is an identical legacy copy) |
| `Pipeline/data/vectorstore.db` | built index (source of truth, written by `ingestion/build_index.py`) |
| `Pipeline/vectorstore.db` | tracked copy of a deployed index; not written by the pipeline |
| `App/Resources/vectorstore.db` | index shipped in the app bundle |
| `App/Backend/Services/RAG/SQLiteRetriever.swift` | on-device hybrid retrieval |
| `App/Backend/Services/RAG/QueryEmbedder.swift` | CoreML BGE-small query encoder |
| `App/Resources/query_embedder.mlpackage`, `vocab.txt` | bundled encoder and vocabulary (`Pipeline/tools/convert_embedder.py`) |
| `Pipeline/eval/` | golden-set IR evaluation harness |
| `Pipeline/tools/smoke_retrieve.py` | quick ad-hoc retrieval check |
| `Pipeline/tools/remap_qrels.py` | repair stale qrel chunk IDs after a split (exact) or a re-chunk (approximate) |
| `Pipeline/tools/ab_retrieval.py` | A/B sweep of retrieval variants |

---

## 10. Open items

- **Oversized chunks (§4):** resolved by the split stage (`final/chunk-splitting`).
- **Ranking:** hybrid retrieval puts the right document in the top 5 far more often than the exact
  gold chunk; a cross-encoder reranker over the fused candidates is the next lever.
- **Vector-pass latency (§6):** `always_fuse` embeds every query on-device;
  measure real-device latency and consider a BM25-confidence gate if needed.
- **Eval coverage:** qrels mostly label a single gold chunk per query (groups exist only for
  split pieces); multi-chunk relevance and modelling query enrichment would tighten the metrics.
- **Semantic-chunker eval:** the eval currently runs the neural experiment only;
  re-add a semantic experiment to compare chunking strategies head-to-head.
