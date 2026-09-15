"""Pool extra relevance judgements for the golden set with an LLM judge (TREC-style pooling).

The golden set marks one gold passage per question (the pieces of a split chunk count as one). A
retriever that returns a different chunk which also answers the question scores nothing for it, so
recall@5 understates every system and cannot tell a system that finds *an* answer from one that
finds nothing — the gap between doc-hit@5 (0.78) and recall@5 (0.22) is mostly that question.
Pooling answers it the way TREC does: take the top of several runs, grade each unjudged
(question, chunk) pair, and score systems against the enlarged, graded set.

  pool    union of retrieved_chunk_ids at --depth over every experiment in --runs (eval.run_eval
          result files, which must all come from one index), minus chunks already in gold groups
  judge   an OpenAI-compatible model grades each pair 0/1/2 with JUDGE_PROMPT at temperature 0;
          judgements are appended to --judgments as they arrive, so an interrupted run resumes and
          no pair is judged twice by the same model
  write   --out: gold groups at grade 2, judged chunks graded 1 or 2 as their own groups, grade-0
          chunks as judged_nonrelevant (so scoring can tell "judged irrelevant" from "never judged")

The judge is a model, not a clinician. Grade a sample by hand before trusting pooled scores:
    python -m tools.pool_qrels export-sample --judgments eval/data/pooled_judgments.jsonl --out sample.csv
    (fill in human_grade)
    python -m tools.pool_qrels agreement --sample sample.csv

Run from Pipeline/:
    python -m tools.pool_qrels pool --runs eval/results/eval_A.json \\
        --index eval/outputs/vectorstore_neural.db --judgments eval/data/pooled_judgments.jsonl \\
        --out eval/data/qrels_pooled.jsonl --base-url http://127.0.0.1:8080 --model <judge>
"""

from __future__ import annotations

import argparse
import csv
import json
import random
import re
import sqlite3
import sys
from pathlib import Path
from typing import Callable

_PIPELINE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_PIPELINE))

from eval.dataset import QrelItem, load_qrels, load_queries  # noqa: E402
from eval.metrics_ir import relevance_groups  # noqa: E402

JUDGE_SYSTEM = "You grade search results for a patient-education assistant about colorectal cancer care."
JUDGE_PROMPT = """Question: {question}

Passage:
{passage}

How well does the passage answer the question?
2 = it directly answers the question: a patient could get the answer from this passage alone
1 = it is on topic and answers part of the question, or needs other passages to be useful
0 = it does not help answer the question

Reply with the grade only, as: Grade: <0, 1 or 2>"""

Judge = Callable[[str, str], str]


def parse_grade(reply: str) -> int | None:
    labelled = re.findall(r"grade\s*[:=]\s*([012])\b", reply, flags=re.IGNORECASE)
    if labelled:
        return int(labelled[-1])
    bare = re.fullmatch(r"\s*([012])\s*\.?\s*", reply)
    return int(bare.group(1)) if bare else None


def load_runs(paths: list[Path], allow_mixed_index: bool = False) -> list[dict]:
    runs: list[dict] = []
    for path in paths:
        result = json.loads(path.read_text(encoding="utf-8"))
        for exp in result["experiments"]:
            runs.append(
                {
                    "label": f"{path.name}:{exp['experiment']}",
                    "index_sha256": exp.get("provenance", {}).get("index", {}).get("sha256"),
                    "retrieved": {row["query_id"]: row["retrieved_chunk_ids"] for row in exp["per_query"]},
                }
            )
    indexes = {run["index_sha256"] for run in runs}
    if len(indexes) > 1 and not allow_mixed_index:
        raise SystemExit(f"runs come from different indexes {sorted(map(str, indexes))}; pool one corpus at a time")
    return runs


def pool_candidates(runs: list[dict], qrels: dict[str, QrelItem], depth: int) -> dict[str, list[str]]:
    pool: dict[str, list[str]] = {}
    for query_id, item in qrels.items():
        gold = {cid for group in relevance_groups(item.relevance()) for cid in group}
        seen: dict[str, None] = {}
        for run in runs:
            for chunk_id in run["retrieved"].get(query_id, [])[:depth]:
                if chunk_id not in gold:
                    seen.setdefault(chunk_id, None)
        pool[query_id] = list(seen)
    return pool


def load_judgments(path: Path) -> list[dict]:
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def judge_pool(
    pool: dict[str, list[str]],
    questions: dict[str, str],
    passages: dict[str, str],
    judge: Judge,
    model: str,
    judgments_path: Path,
) -> dict[str, int]:
    """Judge every pooled pair not yet judged by `model`; returns counts."""
    done = {(j["query_id"], j["chunk_id"]) for j in load_judgments(judgments_path) if j["judge_model"] == model}
    counts = {"already_judged": 0, "judged": 0, "unparsed": 0}
    judgments_path.parent.mkdir(parents=True, exist_ok=True)
    with judgments_path.open("a", encoding="utf-8") as sink:
        for query_id, chunk_ids in pool.items():
            for chunk_id in chunk_ids:
                if (query_id, chunk_id) in done:
                    counts["already_judged"] += 1
                    continue
                reply = judge(JUDGE_SYSTEM, JUDGE_PROMPT.format(question=questions[query_id], passage=passages[chunk_id]))
                grade = parse_grade(reply)
                if grade is None:
                    # Not recorded, so the next run asks again rather than freezing a bad parse.
                    counts["unparsed"] += 1
                    continue
                sink.write(json.dumps({"query_id": query_id, "chunk_id": chunk_id, "grade": grade, "judge_model": model}) + "\n")
                sink.flush()
                counts["judged"] += 1
    return counts


def build_pooled_qrels(qrels: dict[str, QrelItem], judgments: list[dict], model: str) -> list[dict]:
    by_query: dict[str, list[dict]] = {}
    for j in judgments:
        if j["judge_model"] == model:
            by_query.setdefault(j["query_id"], []).append(j)
    rows: list[dict] = []
    for query_id, item in qrels.items():
        gold_groups = [sorted(group) for group in relevance_groups(item.relevance())]
        gold = {cid for group in gold_groups for cid in group}
        groups = [{"chunk_ids": group, "grade": 2, "source": "gold"} for group in gold_groups]
        nonrelevant: list[str] = []
        for j in sorted(by_query.get(query_id, []), key=lambda j: j["chunk_id"]):
            if j["chunk_id"] in gold:
                continue
            if j["grade"] > 0:
                groups.append({"chunk_ids": [j["chunk_id"]], "grade": j["grade"], "source": "judge"})
            else:
                nonrelevant.append(j["chunk_id"])
        rows.append({"query_id": query_id, "groups": groups, "judged_nonrelevant": nonrelevant, "judge_model": model})
    return rows


def export_sample(judgments: list[dict], questions: dict[str, str], passages: dict[str, str], n: int, seed: int, out: Path) -> int:
    rng = random.Random(seed)
    sample = rng.sample(judgments, min(n, len(judgments)))
    with out.open("w", encoding="utf-8", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["query_id", "chunk_id", "question", "passage", "judge_grade", "human_grade"])
        for j in sample:
            writer.writerow([j["query_id"], j["chunk_id"], questions[j["query_id"]], passages[j["chunk_id"]], j["grade"], ""])
    return len(sample)


def agreement(sample_csv: Path) -> dict:
    from tools.score_answer_sheet import interpret_kappa, weighted_kappa

    judge, human = [], []
    with sample_csv.open(encoding="utf-8", newline="") as f:
        for row in csv.DictReader(f):
            if row["human_grade"].strip():
                judge.append(int(row["judge_grade"]))
                human.append(int(row["human_grade"]))
    kappa = weighted_kappa(judge, human, categories=3)
    exact = sum(a == b for a, b in zip(judge, human)) / len(judge) if judge else None
    return {"pairs": len(judge), "weighted_kappa": kappa, "band": interpret_kappa(kappa), "exact_agreement": exact}


def read_passages(index: Path, chunk_ids: set[str]) -> dict[str, str]:
    conn = sqlite3.connect(f"file:{index}?mode=ro", uri=True)
    try:
        rows = conn.execute("SELECT chunk_id, text FROM chunks").fetchall()
    finally:
        conn.close()
    passages = {cid: text for cid, text in rows if cid in chunk_ids}
    missing = chunk_ids - passages.keys()
    if missing:
        raise SystemExit(f"{len(missing)} pooled chunks are not in {index}, e.g. {sorted(missing)[:3]}")
    return passages


def openai_compatible_judge(base_url: str, model: str, api_key: str | None, timeout_s: int = 120) -> Judge:
    import httpx

    headers = {"Authorization": f"Bearer {api_key}"} if api_key else {}

    def judge(system: str, user: str) -> str:
        response = httpx.post(
            f"{base_url.rstrip('/')}/v1/chat/completions",
            headers=headers,
            json={
                "model": model,
                "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
                "temperature": 0.0,
                "max_tokens": 16,
            },
            timeout=timeout_s,
        )
        response.raise_for_status()
        return response.json()["choices"][0]["message"]["content"]

    return judge


def main() -> None:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    eval_data = _PIPELINE / "eval" / "data"

    pool = sub.add_parser("pool")
    pool.add_argument("--runs", type=Path, nargs="+", required=True)
    pool.add_argument("--index", type=Path, required=True)
    pool.add_argument("--judgments", type=Path, default=eval_data / "pooled_judgments.jsonl")
    pool.add_argument("--out", type=Path, default=eval_data / "qrels_pooled.jsonl")
    pool.add_argument("--depth", type=int, default=10)
    pool.add_argument("--base-url", required=True)
    pool.add_argument("--model", required=True)
    pool.add_argument("--api-key", default=None)
    pool.add_argument("--allow-mixed-index", action="store_true")

    sample = sub.add_parser("export-sample")
    sample.add_argument("--judgments", type=Path, default=eval_data / "pooled_judgments.jsonl")
    sample.add_argument("--index", type=Path, required=True)
    sample.add_argument("--n", type=int, default=60)
    sample.add_argument("--seed", type=int, default=42)
    sample.add_argument("--out", type=Path, required=True)

    agree = sub.add_parser("agreement")
    agree.add_argument("--sample", type=Path, required=True)

    for p in (pool, sample):
        p.add_argument("--queries", type=Path, default=eval_data / "queries.jsonl")
        p.add_argument("--qrels", type=Path, default=eval_data / "qrels.jsonl")
    args = parser.parse_args()

    if args.command == "agreement":
        print(json.dumps(agreement(args.sample), indent=2))
        return

    questions = {q.query_id: q.question for q in load_queries(args.queries)}
    if args.command == "export-sample":
        judgments = load_judgments(args.judgments)
        passages = read_passages(args.index, {j["chunk_id"] for j in judgments})
        count = export_sample(judgments, questions, passages, args.n, args.seed, args.out)
        print(f"wrote {count} pairs to {args.out}; fill in human_grade, then run `agreement`")
        return

    qrels = load_qrels(args.qrels)
    pooled = pool_candidates(load_runs(args.runs, args.allow_mixed_index), qrels, args.depth)
    passages = read_passages(args.index, {cid for ids in pooled.values() for cid in ids})
    print(f"pool: {sum(map(len, pooled.values()))} unjudged-by-gold pairs over {len(pooled)} questions")
    counts = judge_pool(
        pooled, questions, passages, openai_compatible_judge(args.base_url, args.model, args.api_key), args.model, args.judgments
    )
    rows = build_pooled_qrels(qrels, load_judgments(args.judgments), args.model)
    args.out.write_text("".join(json.dumps(r) + "\n" for r in rows), encoding="utf-8")
    added = sum(1 for r in rows for g in r["groups"] if g["source"] == "judge")
    print(json.dumps({**counts, "judged_relevant_groups_added": added, "out": str(args.out)}, indent=2))


if __name__ == "__main__":
    main()
