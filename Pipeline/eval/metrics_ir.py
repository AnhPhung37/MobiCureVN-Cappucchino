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


def doc_id_of(chunk_id: str) -> str:
    """Chunk IDs are `<doc_id>_c<NNN>` (see ingestion/build_index.py)."""
    head, sep, tail = chunk_id.rpartition("_c")
    if sep and tail.isdigit():
        return head
    return chunk_id


def doc_hit_at_k(relevant_ids: set[str], retrieved_ids: list[str], k: int) -> float:
    """Did any top-k chunk come from a document that holds a gold chunk?

    Most queries carry a single labelled gold chunk, so re-chunking makes the
    retriever surface a correct *neighbour* and recall@k under-counts a result
    that is in fact usable. doc-hit@k is the looser, more honest companion --
    it is reported alongside recall@k, never instead of it.
    """
    if not relevant_ids:
        return 0.0
    gold_docs = {doc_id_of(cid) for cid in relevant_ids}
    return 1.0 if any(doc_id_of(cid) in gold_docs for cid in retrieved_ids[:k]) else 0.0
