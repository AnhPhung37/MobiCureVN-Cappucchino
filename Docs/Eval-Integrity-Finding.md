# Evaluation Integrity — what went wrong, and the numbers that stand

_Rewritten 2026-09-13. This file is the **single source of truth** for retrieval metrics.
Where any other document disagrees, this one wins, and that document is out of date._

Success criterion #2 asks for ">90% accuracy in retrieving correct medical references".
Answering it honestly first required fixing how we measure — and then noticing that the app
did not ship the retriever we were measuring. Four defects, found one after another.

> **Correction to the previous version of this file.** It said that after the golden set was
> rebuilt, the harness went on scoring a 9-document index (gold coverage 0.367), that this capped
> every score, and that fixing it "did not improve accuracy because the corpus grew 4.3× at the
> same time". The repository history does not support that. The eval config has pointed at the
> 39-document `data/neural_chunks` since the merge of 24 July, and the committed July results
> retrieve from 38–39 distinct documents. The 69/188 coverage figure is true of the leftover
> `Pipeline/neural_chunks` directory, but no reported number was computed against it, and the
> "before" and "after" figures matched to four digits because they came from the same index.
> What was actually wrong is Defect 2 below.

---

## Defect 1 — the golden set leaked its own labels

**Symptom.** The harness reported `recall@5 = 1.00, MRR = 0.88, nDCG@5 = 0.90` for neural
chunking against `0.125 / 0.05 / 0.07` for semantic, recorded in `Docs/BE/nextStep.md` as "a
real, defensible finding — lead with it in the report".

**Cause.** The 30-query golden set had been generated *from the neural chunks it was then used to
score*, on the 9-document corpus of the time (the May result retrieves from 7 documents). Each
query's gold chunk was, by construction, the chunk the question was written from. The table
measured the labelling procedure, not the retriever.

**Fix.** In July the corpus grew to 39 documents and the golden set was rebuilt to **209 queries**,
with chunk IDs realigned by `Pipeline/tools/remap_qrels.py`.

**Lesson.** A metric that cannot fail is not a metric. Perfect recall on a 5-chunk budget over a
1200-chunk corpus should have been treated as a bug report, not a result.

---

## Defect 2 — the harness scored a retriever the app no longer had

**Symptom.** After the rebuild every configuration scored between 0.187 and 0.249, and the number
quoted depended on who ran what.

**Cause.** `SQLiteRetriever.swift` always runs the vector pass and fuses it with FTS, and drops
stopwords from the FTS query. The harness's `runner.py` defaulted both behaviours to *off*: it
skipped the vector pass whenever FTS returned a full candidate set (the app's old rule) and kept
stopwords. `run_eval` therefore scored an older retriever, and the better figure came from a side
tool (`tools/ab_retrieval.py`) that nothing tied to a commit or an index.

Measured on the same 1238-chunk / 39-document index, 209 queries, `top_k = 5`:

| Harness | recall@5 | doc-hit@5 | MRR | nDCG@5 |
|---|---|---|---|---|
| `main` (vector skipped when FTS is full, stopwords kept) | 0.1866 | 0.6890 | 0.0967 | 0.1193 |
| `final/eval-integrity` (as `SQLiteRetriever` runs) | **0.2488** | **0.7703** | **0.1589** | **0.1814** |

**Fix** (`final/eval-integrity`): the runner defaults `always_fuse` and `drop_stopwords` to what the
app ships; the 9-document semantic experiment is disabled with its reason in the config; `doc_hit@k`
is computed by the harness; every result carries provenance (git commit and dirty flag, index
sha256, chunk/doc counts, corpus fingerprint, package versions, gold-chunk coverage) and `run_eval`
warns when coverage < 1.0.

---

## Defect 3 — the app did not ship the retriever being scored

**Symptom.** None in the app: retrieval quietly worked, just worse.

**Cause.** `App/Resources` contained neither `query_embedder.mlpackage` nor `vocab.txt`.
`QueryEmbedder()` returned `nil` on every build of this repository and `SQLiteRetriever` searched
**FTS-only** — while every retrieval number in the docs described the hybrid retriever.

Producing the model exposed three more defects on the path it would have taken, any one of which
would have kept vector search broken:

- the converter **mean-pooled**, but `bge-small-en-v1.5` pools the `[CLS]` token and the index is
  built with that pooling, so query vectors would not have matched document vectors;
- its FP16 conversion emitted a **FLOAT16** output that `QueryEmbedder` does not read, so
  `embed()` would have returned `nil`;
- `WordPieceTokenizer.swift` did not tokenize like the Python tokenizer (no accent stripping,
  symbols split as punctuation, no CJK isolation or control-character cleaning).

| What a build shipped | recall@5 | doc-hit@5 | MRR | nDCG@5 |
|---|---|---|---|---|
| before `final/eval-integrity` — FTS-only | 0.2201 | 0.7081 | 0.1300 | 0.1525 |
| with the bundled embedder — hybrid | 0.2488 | 0.7703 | 0.1589 | 0.1814 |

**Fix** (`final/eval-integrity`): the embedder and vocabulary are bundled; the converter reads the
pooling from the model config, forces FLOAT32 output and refuses to convert unless it matches
`SentenceTransformer` at cosine ≥ 0.9999; the tokenizer mirrors the Hugging Face pipeline (a Python
port matches it on all 1465 corpus/query/fixture texts); `QueryEmbedderParityTests` checks tokenizer
and model on device against an exported fixture; the harness records whether the tree bundles the
embedder and scores an FTS-only experiment beside the hybrid one.

**Not yet verified:** nothing Swift or CoreML could run where this was built. The hybrid row
describes the app once `QueryEmbedderParityTests` pass on the device (Docs/Test-Protocol.md §2.1).

---

## Defect 4 — the provenance could not vouch for itself

The dirty flag counted the harness's own output files, so the second of three back-to-back runs
always reported `dirty: true`; the results then committed recorded `dirty: null` from before that
flag was fixed; and result files carried one machine's absolute paths. All three are fixed, and the
committed results were regenerated from a clean tree.

---

## The numbers that stand

Measured 2026-09-13 with `final/eval-integrity`, 209 queries, `top_k = 5`, index `91e459a6edd1`
(1238 chunks / 39 documents), gold-chunk coverage **1.000** (188/188):

| Retriever | recall@5 | doc-hit@5 | MRR | nDCG@5 |
|---|---|---|---|---|
| **hybrid — the app, with the bundled embedder** | **0.2488** | **0.7703** | **0.1589** | **0.1814** |
| FTS-only — a build without it | 0.2201 | 0.7081 | 0.1300 | 0.1525 |

Three consecutive runs at one commit, all `dirty: false`, produced byte-identical retrieved chunk
lists: `Pipeline/eval/results/eval_20260912T225838Z.json`, `eval_20260912T225853Z.json`,
`eval_20260913T025757Z.json`.

**Do not present a retrieval number that is not in a result file**, and do not transcribe one into
prose elsewhere — that is how contradictory figures ended up in this repo at the same time.

### What recall@5 actually measures here

**207 of the 209 queries label exactly one gold chunk.** With a single gold chunk, recall@5 is a hit
rate: "was that one specific chunk in the top 5". It gives no credit for an equally correct
neighbour.

- exact gold chunk in top 5: **52/209**
- a chunk from the correct *document* in top 5: **161/209**

`doc-hit@5` is the companion that reflects whether the model was handed the right source material.

### What reaches the model

Retrieval quality is not grounding quality: the context budget decides what the model reads. With
the packer on `final/context-budget-fix`, doc-hit of the chunks the model actually receives is
**0.7416** at `top_k = 5` / budget 2000, and **0.8134** at `top_k = 10` / budget 3000 (Qwen 3.5;
`Docs/BE/Context-Budget-Finding.md`). Before that fix it was 0.4450.

**Against criterion #2 (>90%):** no figure reaches it. Report them as measured and discuss the gap.

---

## How to tell this story in the presentation

> **We caught our evaluation — and our app — measuring different things.**
>
> 1. Our first golden set scored 1.00 recall. The labels had been generated from the chunks being
>    scored. We rebuilt it: 209 queries over 39 documents.
> 2. The harness then scored a retriever the app no longer used (recall@5 0.187 instead of 0.249).
> 3. And the app was not shipping the vector half at all: no embedder in the bundle, so every
>    search was keyword-only (0.220). The converter would have built a model that disagreed with
>    the index three different ways.
> 4. Now every result carries the commit, the index hash, the corpus fingerprint, the coverage and
>    whether the build is hybrid or FTS-only, and a device test proves the phone embeds queries the
>    way the index was built.
>
> **Measured: recall@5 0.249, doc-hit@5 0.770, and 0.813 of what the model reads comes from the
> right document — reproducible to the digit.**

Expect *"so what was your accuracy before?"* The honest answer: "the app was keyword-only at
recall@5 0.220 / doc-hit@5 0.708, and our harness was reporting 0.187 for a retriever the app no
longer had."

Levers that remain, each on its own branch: a cross-encoder reranker (retrieval ranks the right
document in the top 5 for 161 queries but the exact chunk for only 52), splitting oversized chunks
(`final/chunk-splitting`), and multi-chunk relevance labels — the last improves the *measurement*,
not the system; say so if you use it.
