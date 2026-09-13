from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from .utils import read_jsonl


@dataclass(frozen=True)
class QueryItem:
    query_id: str
    question: str
    language: str | None = None
    reference_answer: str | None = None


@dataclass(frozen=True)
class QrelItem:
    query_id: str
    relevant_chunk_ids: list[str]
    # Present once a split corpus has been remapped (tools/remap_qrels.py
    # --from-split-provenance): the pieces of each original gold chunk, as one group.
    relevant_groups: list[list[str]] | None = None

    def relevance(self) -> set[str] | list[list[str]]:
        """What eval.metrics_ir scores: the groups when present, else one group per chunk ID."""
        return self.relevant_groups if self.relevant_groups else set(self.relevant_chunk_ids)


def load_queries(path: Path) -> list[QueryItem]:
    raw = read_jsonl(path)
    queries: list[QueryItem] = []
    for item in raw:
        queries.append(
            QueryItem(
                query_id=item["query_id"],
                question=item["question"],
                language=item.get("language"),
                reference_answer=item.get("reference_answer"),
            )
        )
    return queries


def load_qrels(path: Path) -> dict[str, QrelItem]:
    raw = read_jsonl(path)
    qrels: dict[str, QrelItem] = {}
    for item in raw:
        qrels[item["query_id"]] = QrelItem(
            query_id=item["query_id"],
            relevant_chunk_ids=item.get("relevant_chunk_ids", []),
            relevant_groups=item.get("relevant_groups"),
        )
    return qrels


def validate_dataset(queries: list[QueryItem], qrels: dict[str, QrelItem]) -> None:
    seen = set()
    for q in queries:
        if q.query_id in seen:
            raise ValueError(f"Duplicate query_id: {q.query_id}")
        seen.add(q.query_id)
        if not q.question.strip():
            raise ValueError(f"Empty question for query_id: {q.query_id}")
        if q.query_id not in qrels:
            raise ValueError(f"Missing qrels for query_id: {q.query_id}")

    for qid, rel in qrels.items():
        if not rel.relevant_chunk_ids:
            raise ValueError(f"Empty relevant_chunk_ids for query_id: {qid}")
        if rel.relevant_groups is not None:
            grouped = [cid for group in rel.relevant_groups for cid in group]
            if any(not group for group in rel.relevant_groups) or set(grouped) != set(rel.relevant_chunk_ids):
                raise ValueError(
                    f"relevant_groups for {qid} must be non-empty and cover exactly relevant_chunk_ids"
                )
