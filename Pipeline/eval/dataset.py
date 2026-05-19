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
