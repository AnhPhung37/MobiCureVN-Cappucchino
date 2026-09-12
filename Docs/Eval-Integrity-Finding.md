# Evaluation Integrity — what went wrong, and the number that stands

_Written 2026-09-12. This file is the **single source of truth** for retrieval metrics.
Where any other document disagrees, this one wins, and that document is out of date._

Success criterion #2 asks for ">90% accuracy in retrieving correct medical references".
Answering it honestly first required fixing how we measure. Two separate defects were
found in the evaluation harness, one after the other. Neither was in the retriever.

---

## Defect 1 — the golden set leaked its own labels

**Symptom.** The harness reported `recall@5 = 1.00, MRR = 0.88, nDCG@5 = 0.90` for
neural chunking against `0.125 / 0.05 / 0.07` for semantic. This was recorded in
`Docs/BE/nextStep.md` as "a real, defensible finding — lead with it in the report".

**Cause.** The 30-query golden set had been generated *from the neural chunks it was
then used to score*. Each query's gold chunk was, by construction, the chunk the
question had been written from. The neural column could not have been anything other
than near-perfect; the semantic column was scored against labels belonging to a
different chunking, so it could not have been anything other than near-zero. The table
measured the labelling procedure, not the retriever.

**Fix.** The golden set was rebuilt to **209 queries** with chunk IDs realigned across
re-chunking (`Pipeline/tools/remap_qrels.py`). Reported scores immediately fell to the
0.19–0.25 band.

**Lesson for the report.** A metric that cannot fail is not a metric. The tell was the
number itself: perfect recall on a 5-chunk budget over a 1200-chunk corpus should have
been treated as a bug report, not a result.

---

## Defect 2 — the harness scored a corpus the app does not ship

**Symptom.** After the rebuild, every configuration scored between 0.187 and 0.249, no
matter what was changed. Two runs minutes apart returned different chunks for all 209
queries. The low ceiling was rationalised in the docs as an artifact of single-gold-chunk
labelling, with `doc-hit@5 ≈ 0.77` offered as the "more trustworthy" figure.

**Cause.** `Pipeline/eval/experiment_config.json` pointed `source_chunks_dir` at
`../neural_chunks` — a **9-document** leftover from an earlier pipeline layout. The
shipped index (`App/Resources/vectorstore.db`) is built from `../data/neural_chunks`:
**39 documents, 1238 chunks**. The golden set labels chunks across all 39.

Measured directly against the two indexes:

| Index under test | Gold chunks present | Coverage | Max achievable recall@5 |
|---|---|---|---|
| `Pipeline/neural_chunks` (9 docs) — what the eval used | 69 / 188 | **0.367** | 0.367 |
| `App/Resources/vectorstore.db` (39 docs) — what ships | 188 / 188 | **1.000** | 1.000 |

Every reported score sat under a 0.367 ceiling imposed by the harness, not by the
retriever. Nothing bound a result file to the index that produced it, so rebuilding the
index between runs silently changed the answer while the recorded config stayed identical.

**Fix** (`final/eval-integrity`):

- the config points at `../data/neural_chunks` and `../data/registry.csv`;
- the semantic experiment is explicitly disabled — only 9 of 39 documents are
  semantically chunked, so it is not a like-for-like comparison, and the reason now
  travels inside the config rather than in someone's memory;
- `runner.py` defaults `always_fuse` and `drop_stopwords` to **true**, matching what
  `SQLiteRetriever.swift:55-62` actually ships. The eval had been scoring a retriever
  the app does not have;
- `doc_hit@k` is computed by the harness and written to every result;
- every result now carries **provenance**: git commit + dirty flag, index sha256,
  chunk/doc counts, corpus fingerprint, package versions, and gold-chunk coverage.
  `run_eval` prints a warning when coverage < 1.0 — the exact condition that hid this
  bug for months.

---

## The number that stands

Measured 2026-09-12 on the corrected harness, over the 209-query golden set,
`top_k = 5`, index `55025e8fb094` (1238 chunks / 39 documents).

| Metric | Value |
|---|---|
| gold-chunk coverage | **1.000** (188/188) |
| recall@5 | **0.2488** |
| doc-hit@5 | **0.7703** |
| MRR | **0.1589** |
| nDCG@5 | **0.1814** |

Run three times consecutively. All three produced **byte-identical** retrieved chunk
lists for all 209 queries and identical metrics. Reproducibility is fixed.

Artifacts: `Pipeline/eval/results/eval_20260912T0851{37,51,05}Z.json`, each carrying its
own index sha256, corpus fingerprint, git commit and coverage.

**Do not present a retrieval number that is not in this table**, and do not transcribe
one into prose elsewhere — that is how three mutually contradictory figures ended up in
this repo at the same time.

### Fixing the corpus did not improve accuracy

This is the part to say out loud rather than bury.

| | recall@5 | doc-hit@5 | coverage |
|---|---|---|---|
| before (9-doc index) | 0.249 | 0.770 | 0.367 |
| after (39-doc index) | 0.2488 | 0.7703 | 1.000 |

The expectation, when the coverage defect was found, was that restoring the missing 63%
of gold chunks would raise recall substantially. **It did not.** The corpus grew 4.3x, so
the retriever gained access to every gold chunk and simultaneously acquired four times
the distractors; the two effects cancelled almost exactly.

So the old number was *right by accident*, and the accident concealed something real:
relative to what was achievable, retrieval got worse (0.249 of a 0.367 ceiling = 68%;
0.2488 of a 1.000 ceiling = 25%). The defect was real and worth fixing — the measurement
is now trustworthy and reproducible — but it was not the explanation for the low score.
Retrieval genuinely performs at recall@5 ≈ 0.25 and doc-hit@5 ≈ 0.77.

### What recall@5 actually measures here

**207 of the 209 queries label exactly one gold chunk** (mean 1.01 per query). With a
single gold chunk, recall@5 collapses into a hit rate: "was that one specific chunk in
the top 5". It carries no partial credit and no notion of an equally-correct neighbour.

- exact gold chunk in top 5: **52/209**
- a chunk from the correct *document* in top 5: **161/209**

`doc-hit@5 = 0.770` is therefore the metric that reflects whether the model was handed
the right source material — which is what actually determines whether the answer is
grounded. This is a defensible reading of the numbers, but note the difference from how
it was used before: previously it was quoted to explain away a plumbing bug, and it was
computed by an untracked side tool. It is now produced by the harness itself, on a
corpus that matches what ships.

**Against criterion #2 (>90%):** neither figure reaches it. Report both, explain the
single-gold-chunk labelling honestly, and discuss the gap. See below.

---

## How to tell this story in the presentation

It is a stronger slide than a clean number would have been. Suggested shape, one slide:

> **We caught our own evaluation lying to us. Twice.**
>
> 1. Our first golden set scored 1.00 recall. We didn't celebrate — we asked why a
>    5-chunk retrieval over 1200 chunks was perfect. The labels had been generated from
>    the chunks being scored.
> 2. We rebuilt it to 209 queries. Scores collapsed to ~0.2 and refused to move no
>    matter what we tuned. That was the second bug: the harness was scoring a 9-document
>    index against a 39-document answer key. 63% of correct answers were not in the
>    index we were searching.
> 3. Fixed, and made unrepeatable: every result now carries the index hash, the corpus
>    fingerprint, and the gold-chunk coverage. The harness refuses to stay quiet when
>    coverage < 100%.
>
> **Measured: recall@5 = 0.249, doc-hit@5 = 0.770, reproducible to the digit.**
> And the honest punchline: fixing the corpus bug did *not* raise the score. We expected
> it to. It did not, because the corpus grew 4.3x at the same time. We can now tell the
> difference between a bad retriever and a broken measurement — which is the only reason
> the number means anything.

Expect the question *"so what was your accuracy before you found the bug?"* The answer
is: "a number we couldn't have defended, which is why we don't quote it." Say it plainly.

It does fall short of the 90% criterion, so report it as measured and discuss it:
single-gold-chunk labelling genuinely does deflate exact-chunk recall (207 of 209 queries
label one chunk), `doc-hit@5 = 0.77` is the honest companion metric, and the retrieval
budget — five chunks into the LLM — is what actually determines whether the answer is
grounded. That discussion is worth more marks than a number nobody can reproduce.

Concrete levers, if there is time to move the number:

- **`top_k`.** Five chunks is a latency choice, not an accuracy one. doc-hit@10 is free
  to measure and will be materially higher; if the context budget can absorb it, this is
  the cheapest real gain.
- **Oversized chunks.** 18% of chunks exceed the 512-token embedder window (§4 of
  `RAG-Pipeline-and-Evaluation.md`), so their tails are never embedded. Splitting them is
  a corpus fix, not a retriever fix.
- **Multi-chunk relevance labels.** Labelling every chunk that genuinely answers a query,
  rather than one, would make recall@5 mean what people assume it means. This improves the
  *measurement*, not the system — say so if you do it.
