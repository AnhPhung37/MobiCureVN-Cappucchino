from __future__ import annotations

import math


def recall_at_k(relevant_ids: set[str], retrieved_ids: list[str], k: int) -> float:
    if not relevant_ids:
        return 0.0
    retrieved_k = set(retrieved_ids[:k])
    return len(retrieved_k & relevant_ids) / len(relevant_ids)


def mrr(relevant_ids: set[str], retrieved_ids: list[str]) -> float:
    for idx, item in enumerate(retrieved_ids, start=1):
        if item in relevant_ids:
            return 1.0 / idx
    return 0.0


def ndcg_at_k(relevant_ids: set[str], retrieved_ids: list[str], k: int) -> float:
    if not relevant_ids:
        return 0.0

    def _dcg(items: list[str]) -> float:
        score = 0.0
        for i, item in enumerate(items[:k], start=1):
            if item in relevant_ids:
                score += 1.0 / math.log2(i + 1)
        return score

    dcg = _dcg(retrieved_ids)
    ideal_hits = min(len(relevant_ids), k)
    ideal_dcg = sum(1.0 / math.log2(i + 1) for i in range(1, ideal_hits + 1))
    if ideal_dcg == 0:
        return 0.0
    return dcg / ideal_dcg
