"""Score eval.run_eval result files against pooled qrels (tools/pool_qrels.py).

For every experiment in every result file, at that run's top_k:

  recall (gold)   the run's own recall@k against the original golden set, as reported
  recall >= 2     groups graded "answers the question" retrieved in the top k
  recall >= 1     groups graded at least "partly answers"
  nDCG graded     gain 2^grade - 1, each group credited once
  judged@k        share of the top k that carries a judgement; below 1.0 every graded number is a
                  lower bound, which is what happens to a system that was not in the pool

    python -m tools.score_pooled --pooled eval/data/qrels_pooled.jsonl --runs eval/results/eval_*.json
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

_PIPELINE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_PIPELINE))

from eval.metrics_graded import graded_ndcg_at_k, graded_recall_at_k, judged_at_k  # noqa: E402


def score(pooled_rows: list[dict], result: dict) -> list[dict]:
    pooled = {row["query_id"]: row for row in pooled_rows}
    k = result["config"]["evaluation"]["top_k"]
    scored: list[dict] = []
    for exp in result["experiments"]:
        per_query = exp["per_query"]
        missing = [row["query_id"] for row in per_query if row["query_id"] not in pooled]
        if missing:
            raise SystemExit(f"{exp['experiment']}: {len(missing)} queries have no pooled qrels, e.g. {missing[:3]}")

        def mean(metric) -> float:
            return sum(metric(pooled[row["query_id"]], row["retrieved_chunk_ids"]) for row in per_query) / len(per_query)

        scored.append(
            {
                "experiment": exp["experiment"],
                "k": k,
                "recall_gold": exp["metrics"]["recall@k"],
                "recall_grade2": mean(lambda p, r: graded_recall_at_k(p["groups"], r, k, 2)),
                "recall_grade1": mean(lambda p, r: graded_recall_at_k(p["groups"], r, k, 1)),
                "ndcg_graded": mean(lambda p, r: graded_ndcg_at_k(p["groups"], r, k)),
                "judged_at_k": mean(lambda p, r: judged_at_k(p["groups"], p["judged_nonrelevant"], r, k)),
            }
        )
    return scored


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--pooled", type=Path, required=True)
    parser.add_argument("--runs", type=Path, nargs="+", required=True)
    parser.add_argument("--out", type=Path, default=None)
    args = parser.parse_args()

    pooled_rows = [json.loads(l) for l in args.pooled.read_text(encoding="utf-8").splitlines() if l.strip()]
    report = []
    for path in args.runs:
        for row in score(pooled_rows, json.loads(path.read_text(encoding="utf-8"))):
            report.append({"run": path.name, **row})
    header = f"{'run:experiment':<48} {'k':>2} {'R gold':>7} {'R>=2':>7} {'R>=1':>7} {'nDCG g':>7} {'judged':>7}"
    print(header)
    for r in report:
        print(
            f"{r['run'] + ':' + r['experiment']:<48} {r['k']:>2} {r['recall_gold']:>7.4f} {r['recall_grade2']:>7.4f} "
            f"{r['recall_grade1']:>7.4f} {r['ndcg_graded']:>7.4f} {r['judged_at_k']:>7.4f}"
        )
    if args.out:
        args.out.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
