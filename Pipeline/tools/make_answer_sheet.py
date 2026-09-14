#!/usr/bin/env python3
"""Build a blind scoring sheet for manual answer-quality review.

Success criterion #2 is about retrieval, but the project's real claim is
"non-hallucinatory feedback based on verified medical sources" -- and nothing in
the repo measures the *answer*. The automated harness reports
`answer_similarity = 0.0, faithfulness = 0.0` because `answerer.type = "none"`:
no answer is ever generated, so no answer is ever scored.

Closing that gap automatically needs an answerer wired into the eval loop. Closing
it *credibly, this week* needs two humans and a rubric. This script produces the
sheet they fill in.

Why a stratified sample rather than all 209: a rater's judgement degrades long
before question 209, and 30 carefully scored answers are worth more than 209
skimmed ones.

Usage:
    python -m tools.make_answer_sheet --n 30 --out eval/data/answer_quality
    python -m tools.make_answer_sheet --n 30 --raters 2   # one sheet per rater
"""

from __future__ import annotations

import argparse
import csv
import json
import random
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
QUERIES = ROOT / "eval" / "data" / "queries.jsonl"
# The 209-query golden set is English-only, so on its own it cannot certify
# criterion #4 ("natural and grammatically correct Vietnamese interaction,
# validated by native speakers"). These hand-written Vietnamese questions are
# merged in so every sheet is bilingual.
QUERIES_VI = ROOT / "eval" / "data" / "queries_vi.jsonl"

# Fixed so two raters score the SAME questions and the sheet can be regenerated
# identically. Change it only if you intend a different sample.
SAMPLE_SEED = 42

COLUMNS = [
    "query_id",
    "language",
    "question",
    "model_answer",  # paste the app's answer here
    "citations_shown",  # what the app displayed as sources
    "grounded",  # 0-2  see rubric
    "citation_correct",  # 0-2
    "clinically_safe",  # 0-2  a 0 here vetoes the item regardless of the rest
    "language_quality",  # 0-2
    "completeness",  # 0-2
    "rater_notes",
]


def load_queries(path: Path) -> list[dict]:
    with open(path, encoding="utf-8") as f:
        return [json.loads(line) for line in f if line.strip()]


def stratify(rows: list[dict], n: int) -> list[dict]:
    """Sample proportionally across languages, so a monolingual sheet cannot
    accidentally certify criterion #4."""
    rng = random.Random(SAMPLE_SEED)
    by_lang: dict[str, list[dict]] = {}
    for row in rows:
        by_lang.setdefault(row.get("language", "unknown"), []).append(row)

    picked: list[dict] = []
    langs = sorted(by_lang)
    per_lang = max(1, n // len(langs))
    for lang in langs:
        pool = sorted(by_lang[lang], key=lambda r: r["query_id"])
        rng.shuffle(pool)
        picked.extend(pool[:per_lang])

    # Top up deterministically if integer division left us short.
    if len(picked) < n:
        chosen = {r["query_id"] for r in picked}
        rest = sorted(
            (r for r in rows if r["query_id"] not in chosen),
            key=lambda r: r["query_id"],
        )
        rng.shuffle(rest)
        picked.extend(rest[: n - len(picked)])

    return sorted(picked[:n], key=lambda r: r["query_id"])


def write_sheet(sample: list[dict], out_path: Path, rater: str | None) -> None:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with open(out_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=COLUMNS)
        writer.writeheader()
        for row in sample:
            writer.writerow(
                {
                    "query_id": row["query_id"],
                    "language": row.get("language", ""),
                    "question": row["question"],
                    "model_answer": "",
                    "citations_shown": "",
                    "grounded": "",
                    "citation_correct": "",
                    "clinically_safe": "",
                    "language_quality": "",
                    "completeness": "",
                    "rater_notes": "",
                }
            )
    who = f" for {rater}" if rater else ""
    print(f"Wrote {len(sample)} rows{who} -> {out_path}")


def write_key(sample: list[dict], out_path: Path) -> None:
    """Reference answers live in a SEPARATE file.

    A rater who can see the expected answer while scoring will anchor to it. Score
    first, reconcile against the key afterwards.
    """
    with open(out_path, "w", encoding="utf-8") as f:
        f.write("# Reference answers — open only AFTER scoring\n\n")
        f.write(
            "Anchoring is real: a rater who reads the expected answer first scores the\n"
            "model's answer against that wording rather than against the source material.\n"
            "Use this to reconcile disagreements between raters, not to score.\n\n"
        )
        for row in sample:
            f.write(f"## {row['query_id']} ({row.get('language', '?')})\n\n")
            f.write(f"**Q:** {row['question']}\n\n")
            f.write(f"**Reference:** {row.get('reference_answer', '(none)')}\n\n")
    print(f"Wrote reference key -> {out_path}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--n", type=int, default=30, help="questions to sample (default 30)"
    )
    parser.add_argument(
        "--raters", type=int, default=2, help="sheets to emit (default 2)"
    )
    parser.add_argument(
        "--out",
        type=Path,
        default=ROOT / "eval" / "data" / "answer_quality",
        help="output directory",
    )
    args = parser.parse_args()

    rows = load_queries(QUERIES)
    if QUERIES_VI.exists():
        rows += load_queries(QUERIES_VI)
    sample = stratify(rows, args.n)

    if not any(r.get("language") == "vi" for r in sample):
        raise SystemExit(
            "Sample contains no Vietnamese question -- criterion #4 cannot be scored "
            f"from it. Check {QUERIES_VI}."
        )

    langs: dict[str, int] = {}
    for row in sample:
        langs[row.get("language", "unknown")] = (
            langs.get(row.get("language", "unknown"), 0) + 1
        )
    print(f"Sampled {len(sample)} of {len(rows)} queries; language mix: {langs}")

    for i in range(1, args.raters + 1):
        write_sheet(
            sample, args.out / f"answer_quality_rater{i}.csv", rater=f"rater {i}"
        )
    write_key(sample, args.out / "reference_answers.md")

    print(
        "\nNext: run each question through the app, paste the answer and the citation "
        "titles into every rater's sheet, score independently, then run\n"
        "  python -m tools.score_answer_sheet eval/data/answer_quality/*.csv"
    )


if __name__ == "__main__":
    main()
