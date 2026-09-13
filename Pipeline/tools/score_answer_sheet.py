#!/usr/bin/env python3
"""Aggregate filled-in answer-quality sheets into a reportable result.

Reports per-dimension means, the safety veto count, and inter-rater agreement.
Agreement matters: two raters who never disagree have probably not scored
independently, and a single rater's numbers are an opinion rather than a measurement.

Agreement is reported two ways per dimension: the count of hard disagreements (one
rater 0, another 2), and quadratic-weighted Cohen's kappa -- agreement beyond what
the raters' own score distributions would give by chance, the statistic a panel
expects for an ordinal rubric. With more than two raters, kappa is reported for
every pair and averaged.

Usage:
    python -m tools.score_answer_sheet eval/data/answer_quality/answer_quality_rater*.csv
"""

from __future__ import annotations

import argparse
import csv
import itertools
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


def weighted_kappa(a: list[int], b: list[int], categories: int = MAX_PER_DIMENSION + 1) -> float | None:
    """Quadratic-weighted Cohen's kappa for two raters on an ordinal 0..MAX scale.

    1.0 is perfect agreement, 0 is what chance would give, negative is worse than chance.
    Quadratic weights make a 0-vs-2 disagreement cost four times a 0-vs-1, which is what
    an ordinal rubric means. Returns None when kappa is undefined: fewer than two items,
    or both raters gave one identical score to every item (no variance to agree beyond).
    """
    n = len(a)
    if n != len(b) or n < 2:
        return None
    k = categories
    observed = [[0] * k for _ in range(k)]
    for x, y in zip(a, b):
        observed[x][y] += 1
    rows = [sum(observed[i]) for i in range(k)]
    cols = [sum(observed[i][j] for i in range(k)) for j in range(k)]

    def weight(i: int, j: int) -> float:
        return (i - j) ** 2 / (k - 1) ** 2

    disagreement = sum(weight(i, j) * observed[i][j] for i in range(k) for j in range(k))
    expected = sum(weight(i, j) * rows[i] * cols[j] / n for i in range(k) for j in range(k))
    if expected == 0:
        return None
    return 1.0 - disagreement / expected


def interpret_kappa(value: float | None) -> str:
    """Landis & Koch (1977) bands -- conventional, and what a reader will compare against."""
    if value is None:
        return "undefined"
    if value < 0:
        return "poor"
    for upper, label in ((0.20, "slight"), (0.40, "fair"), (0.60, "moderate"), (0.80, "substantial")):
        if value <= upper:
            return label
    return "almost perfect"


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
        scored_by_all = [
            q for q in sorted(common) if all(dim in sheets[name][q]["scores"] for name in sheets)
        ]
        pair_kappas = {
            f"{r1}~{r2}": weighted_kappa(
                [sheets[r1][q]["scores"][dim] for q in scored_by_all],
                [sheets[r2][q]["scores"][dim] for q in scored_by_all],
            )
            for r1, r2 in itertools.combinations(sheets, 2)
        }
        defined = [v for v in pair_kappas.values() if v is not None]
        kappa = statistics.mean(defined) if defined else None
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
            "weighted_kappa": {
                "pairs": {pair: None if v is None else round(v, 3) for pair, v in pair_kappas.items()},
                "mean": None if kappa is None else round(kappa, 3),
                "interpretation": interpret_kappa(kappa) if len(sheets) > 1 else "one rater",
            },
        }
        flag = (
            "  <-- raters diverge, reconcile"
            if disagreements > len(common) * 0.15 or (kappa is not None and kappa < 0.40)
            else ""
        )
        kappa_text = (
            "kw n/a (one rater)" if len(sheets) == 1
            else "kw undefined" if kappa is None
            else f"kw {kappa:.2f} ({interpret_kappa(kappa)})"
        )
        print(
            f"  {dim:<18} {mean:.2f}/2  ({pct:.0f}%)   {kappa_text}   hard disagreements: {disagreements}{flag}"
        )

    # Per-language split. A single blended figure lets strong English performance
    # mask weak Vietnamese, which is precisely what criterion #4 exists to prevent,
    # and the rubric asks for this split explicitly.
    langs = sorted({sheets[next(iter(sheets))][q]["language"] for q in common})
    if len(langs) > 1:
        print("\n  By language:")
        summary["by_language"] = {}
        for lang in langs:
            qids = [q for q in sorted(common) if sheets[next(iter(sheets))][q]["language"] == lang]
            per_dim = {}
            for dim in DIMENSIONS:
                vals = [
                    sheets[name][q]["scores"][dim]
                    for q in qids
                    for name in sheets
                    if dim in sheets[name][q]["scores"]
                ]
                if vals:
                    per_dim[dim] = round(statistics.mean(vals), 3)
            summary["by_language"][lang] = {"questions": len(qids), "means": per_dim}
            cells = "  ".join(f"{d[:9]}={v:.2f}" for d, v in per_dim.items())
            print(f"    {lang} (n={len(qids):>2})  {cells}")

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
