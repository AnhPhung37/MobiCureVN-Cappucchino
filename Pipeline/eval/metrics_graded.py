"""Graded, group-aware retrieval metrics over pooled qrels (tools/pool_qrels.py).

A pooled qrels row is
    {"query_id": ..., "groups": [{"chunk_ids": [...], "grade": 1 | 2, "source": "gold" | "judge"}],
     "judged_nonrelevant": [...]}

Each group earns credit once, at its first retrieved member — the rule eval.metrics_ir applies to
the pieces of a split gold chunk — so retrieving two pieces of one passage is never rewarded twice.
"""

from __future__ import annotations

import math


def _first_hits(groups: list[dict], retrieved_ids: list[str], k: int) -> list[tuple[int, int]]:
    """(rank, grade) for each group's first member in the top k, in rank order."""
    hits: list[tuple[int, int]] = []
    credited: set[int] = set()
    for rank, chunk_id in enumerate(retrieved_ids[:k], start=1):
        for index, group in enumerate(groups):
            if index not in credited and chunk_id in group["chunk_ids"]:
                credited.add(index)
                hits.append((rank, group["grade"]))
                break
    return hits


def graded_ndcg_at_k(groups: list[dict], retrieved_ids: list[str], k: int) -> float:
    """nDCG with gain 2^grade - 1; unjudged chunks earn nothing."""
    ideal = sorted((g["grade"] for g in groups), reverse=True)[:k]
    ideal_dcg = sum((2**grade - 1) / math.log2(rank + 1) for rank, grade in enumerate(ideal, start=1))
    if ideal_dcg == 0:
        return 0.0
    dcg = sum((2**grade - 1) / math.log2(rank + 1) for rank, grade in _first_hits(groups, retrieved_ids, k))
    return dcg / ideal_dcg


def graded_recall_at_k(groups: list[dict], retrieved_ids: list[str], k: int, min_grade: int) -> float:
    """Fraction of groups graded >= min_grade with a member in the top k."""
    eligible = [g for g in groups if g["grade"] >= min_grade]
    if not eligible:
        return 0.0
    hits = sum(1 for _, grade in _first_hits(eligible, retrieved_ids, k))
    return hits / len(eligible)


def judged_at_k(groups: list[dict], judged_nonrelevant: list[str], retrieved_ids: list[str], k: int) -> float:
    """Share of the top k that carries any judgement. Below 1.0 the graded scores are a lower bound."""
    top = retrieved_ids[:k]
    if not top:
        return 0.0
    judged = {cid for g in groups for cid in g["chunk_ids"]} | set(judged_nonrelevant)
    return sum(1 for cid in top if cid in judged) / len(top)
