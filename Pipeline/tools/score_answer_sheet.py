#!/usr/bin/env python3
"""Aggregate filled-in answer-quality sheets into a reportable result.

Reports per-dimension means, the safety veto count, and inter-rater agreement.
Agreement matters: two raters who never disagree have probably not scored
independently, and a single rater's numbers are an opinion rather than a measurement.

Usage:
    python -m tools.score_answer_sheet eval/data/answer_quality/answer_quality_rater*.csv
"""

from __future__ import annotations

import argparse
import csv
import json
import statistics
from pathlib import Path

DIMENSIONS = [
    "grounded",
    "citation_correct",
    "clinically_safe",
    "language_quality",
    "completeness",
]

MAX_PER_DIMENSION = 2


def read_sheet(path: Path) -> dict[str, dict]:
    with open(path, newline="", encoding="utf-8") as f:
        rows = list(csv.DictReader(f))
    scored: dict[str, dict] = {}
    for row in rows:
        qid = row["query_id"]
        values: dict[str, int] = {}
        for dim in DIMENSIONS:
            raw = (row.get(dim) or "").strip()
            if raw == "":
                continue
            try:
                values[dim] = int(raw)
            except ValueError:
                raise SystemExit(
                    f"{path.name}:{qid}: {dim!r} is {raw!r}, expected 0/1/2"
                )
            if not 0 <= values[dim] <= MAX_PER_DIMENSION:
                raise SystemExit(
                    f"{path.name}:{qid}: {dim} = {values[dim]}, expected 0..2"
                )
        if values:
            scored[qid] = {
                "scores": values,
                "language": row.get("language", ""),
                "notes": row.get("rater_notes", ""),
            }
    return scored


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("sheets", nargs="+", type=Path)
    parser.add_argument(
        "--out", type=Path, default=None, help="write JSON summary here"
    )
    args = parser.parse_args()

    sheets = {p.stem: read_sheet(p) for p in args.sheets}
    for name, rows in sheets.items():
        if not rows:
            raise SystemExit(
                f"{name}: no scored rows -- fill the sheet in before scoring it."
            )

    common = set.intersection(*(set(rows) for rows in sheets.values()))
    if not common:
        raise SystemExit(
            "The sheets share no scored query_id -- raters scored different questions."
        )

    print(f"Raters: {len(sheets)}  |  commonly scored questions: {len(common)}\n")

    summary: dict = {
        "raters": list(sheets),
        "questions_scored": len(common),
        "dimensions": {},
    }

    for dim in DIMENSIONS:
        per_rater_means = []
        all_values = []
        disagreements = 0
        for qid in sorted(common):
            vals = [
                sheets[name][qid]["scores"].get(dim)
                for name in sheets
                if dim in sheets[name][qid]["scores"]
            ]
            if len(vals) < len(sheets):
                continue
            all_values.extend(vals)
            if max(vals) - min(vals) >= 2:  # 0 vs 2 -- raters disagree on the substance
                disagreements += 1
        for name in sheets:
            vals = [
                sheets[name][q]["scores"][dim]
                for q in sorted(common)
                if dim in sheets[name][q]["scores"]
            ]
            if vals:
                per_rater_means.append(statistics.mean(vals))

        if not all_values:
            continue
        mean = statistics.mean(all_values)
        pct = 100 * mean / MAX_PER_DIMENSION
        summary["dimensions"][dim] = {
            "mean": round(mean, 3),
            "percent_of_max": round(pct, 1),
            "per_rater_means": [round(m, 3) for m in per_rater_means],
            "hard_disagreements": disagreements,
        }
        flag = (
            "  <-- raters diverge, reconcile"
            if disagreements > len(common) * 0.15
            else ""
        )
        print(
            f"  {dim:<18} {mean:.2f}/2  ({pct:.0f}%)   hard disagreements: {disagreements}{flag}"
        )

    # The safety veto: any answer scored 0 on clinical safety by ANY rater is a
    # finding on its own, no matter how the averages look. Averages hide these.
    unsafe = [
        qid
        for qid in sorted(common)
        if any(
            sheets[name][qid]["scores"].get("clinically_safe") == 0 for name in sheets
        )
    ]
    summary["clinically_unsafe_query_ids"] = unsafe
    print()
    if unsafe:
        print(
            f"  UNSAFE ANSWERS ({len(unsafe)}) -- report these individually, do not average them away:"
        )
        for qid in unsafe:
            print(f"    {qid}")
    else:
        print("  No answer was scored 0 for clinical safety by any rater.")

    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(json.dumps(summary, indent=2), encoding="utf-8")
        print(f"\nWrote summary -> {args.out}")


if __name__ == "__main__":
    main()
