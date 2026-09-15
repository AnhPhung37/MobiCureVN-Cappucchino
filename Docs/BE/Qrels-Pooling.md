# Qrels pooling: graded judgements beyond the one gold passage

Branch `final0.1-qrels-pooling`. Tooling to enlarge the golden set's relevance judgements with an
LLM judge, TREC-style, and to score existing eval runs against them. The original
`eval/data/qrels.jsonl` is never modified and stays the headline metric until the judge has been
validated against human grades.

## The problem

Each golden question has one gold passage (a split chunk's pieces count as one group). Any other
chunk that also answers the question scores zero. On the split index the hybrid retriever finds a
chunk from the right document for 0.78 of questions at k=5 (doc-hit) but the gold chunk itself for
0.22 (recall). That gap mixes two very different outcomes — a neighbouring chunk that answers the
question, and one that merely shares a document — and the binary qrels cannot say which. The same
blind spot decides reranker and embedder comparisons: a system that trades the gold chunk for an
equally good one looks worse.

## Method

| Step | `python -m tools.pool_qrels …` | What it does |
|---|---|---|
| Pool | `pool --runs <result files> --depth 10` | Union of every experiment's top-10 per question, minus gold. Runs must share one index (sha256 from provenance), or the pool mixes corpora |
| Judge | same command, `--base-url --model` | Grades each pair 0/1/2 (prompt `JUDGE_PROMPT`) at temperature 0; appends to `eval/data/pooled_judgments.jsonl` as it goes, so it resumes after an interruption and never re-judges a pair with the same model; unparseable replies are retried next run, not stored |
| Write | same command, `--out` | `eval/data/qrels_pooled.jsonl`: gold groups at grade 2, judged chunks graded 1–2 as their own groups, grade 0 as `judged_nonrelevant`. A judge never demotes gold |
| Validate | `export-sample --n 60`, then `agreement --sample` | CSV of random judged pairs with a blank `human_grade`; agreement reports quadratic-weighted Cohen's kappa (the answer-quality tool's implementation) and exact agreement |
| Score | `python -m tools.score_pooled --pooled … --runs …` | Per experiment: recall (gold), recall at grade ≥2 and ≥1, graded nDCG, judged@k |

Grades: **2** the passage alone answers the question; **1** on topic, answers part, or needs other
passages; **0** does not help.

Metrics (`eval/metrics_graded.py`) keep `eval.metrics_ir`'s rule that a group earns credit once, at
its first retrieved member. Graded nDCG uses gain 2^grade − 1. **judged@k** is the share of the top
k that carries any judgement: below 1.0 every graded number is a lower bound. A system that was not
in the pool (a new reranker, a new embedder) will show judged@k < 1 — re-pool with its run before
comparing it.

## Before trusting pooled numbers

1. Kappa on a hand-graded sample of at least 60 pairs, by someone who reads the passages, not the
   judge's grades: **substantial (> 0.60)** or better, or the pooled scores are not reported.
2. Report pooled and gold numbers side by side; the pooled ones answer "does the system retrieve an
   answer", the gold ones "does it retrieve the passage the question was written from".
3. Record the judge model; `qrels_pooled.jsonl` carries it per row, and judgements from different
   models are never mixed.

Cost: at depth 10 with two runs (hybrid and FTS-only) about 209 × 10 × 2 pairs before overlap and
minus gold — a few thousand short judge calls.

## Tests

`python -m unittest eval.tests.test_qrels_pooling` (9): grade parsing, pooling at depth without
gold, refusal to mix indexes, resumable per-model judging with a fake judge, gold never demoted,
graded nDCG/recall/judged@k by hand, kappa agreement from a CSV, and pooled scoring end to end.
