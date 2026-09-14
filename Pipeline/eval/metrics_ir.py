from __future__ import annotations

import math
from collections.abc import Iterable

# What a query's gold labels look like to the metrics:
#   * a set of chunk IDs -- each ID is its own relevance group (the original golden set);
#   * a list of groups   -- a group is satisfied by retrieving ANY one of its members.
# Groups exist because ingestion/split_oversized.py turns one gold chunk into several pieces:
# the label said "this chunk answers the question", which after a split means "any of its
# pieces does". Scoring each piece separately would cut a split chunk's recall to 1/pieces.
Relevance = "set[str] | frozenset[str] | list[list[str]]"


def relevance_groups(relevant: Relevance) -> list[frozenset[str]]:
    if isinstance(relevant, (set, frozenset)):
        return [frozenset([cid]) for cid in relevant]
    return [frozenset(group) for group in relevant if group]


def relevant_ids(relevant: Relevance) -> set[str]:
    return {cid for group in relevance_groups(relevant) for cid in group}


def recall_at_k(relevant: Relevance, retrieved_ids: list[str], k: int) -> float:
    """Fraction of relevance groups with at least one member in the top k."""
    groups = relevance_groups(relevant)
    if not groups:
        return 0.0
    top = set(retrieved_ids[:k])
    return sum(1 for group in groups if group & top) / len(groups)


def mrr(relevant: Relevance, retrieved_ids: list[str]) -> float:
    ids = relevant_ids(relevant)
    for idx, item in enumerate(retrieved_ids, start=1):
        if item in ids:
            return 1.0 / idx
    return 0.0


def ndcg_at_k(relevant: Relevance, retrieved_ids: list[str], k: int) -> float:
    """Binary nDCG where each relevance group earns gain once, at its first retrieved member."""
    groups = relevance_groups(relevant)
    if not groups:
        return 0.0

    credited: set[int] = set()
    dcg = 0.0
    for i, item in enumerate(retrieved_ids[:k], start=1):
        for g, group in enumerate(groups):
            if g not in credited and item in group:
                credited.add(g)
                dcg += 1.0 / math.log2(i + 1)
                break

    ideal_hits = min(len(groups), k)
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


def doc_hit_at_k(relevant: Relevance, retrieved_ids: list[str], k: int) -> float:
    """Did any top-k chunk come from a document that holds a gold chunk?

    Most queries carry a single labelled gold chunk, so re-chunking makes the
    retriever surface a correct *neighbour* and recall@k under-counts a result
    that is in fact usable. doc-hit@k is the looser, more honest companion --
    it is reported alongside recall@k, never instead of it.
    """
    ids = relevant_ids(relevant)
    if not ids:
        return 0.0
    gold_docs = {doc_id_of(cid) for cid in ids}
    return 1.0 if any(doc_id_of(cid) in gold_docs for cid in retrieved_ids[:k]) else 0.0
