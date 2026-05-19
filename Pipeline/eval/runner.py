from __future__ import annotations

from dataclasses import asdict
from pathlib import Path

from .dataset import QueryItem, QrelItem
from .metrics_ir import mrr, ndcg_at_k, recall_at_k
from .metrics_qa import answer_similarity, faithfulness, safe_mean
from .retriever import Embedder, SQLiteVecRetriever


def _join_context(chunks: list[str]) -> str:
    return "\n\n".join(chunks)


def run_experiment(
    name: str,
    db_path: Path,
    queries: list[QueryItem],
    qrels: dict[str, QrelItem],
    embedder: Embedder,
    top_k: int,
    answerer=None,
) -> dict:
    retriever = SQLiteVecRetriever(db_path, embedder)

    per_query: list[dict] = []
    recall_scores: list[float] = []
    mrr_scores: list[float] = []
    ndcg_scores: list[float] = []
    ans_rel_scores: list[float] = []
    faith_scores: list[float] = []

    for query in queries:
        rel_ids = set(qrels[query.query_id].relevant_chunk_ids)
        retrieved = retriever.search(query.question, top_k)
        retrieved_ids = [c.chunk_id for c in retrieved]

        r_at_k = recall_at_k(rel_ids, retrieved_ids, top_k)
        mrr_score = mrr(rel_ids, retrieved_ids)
        ndcg_score = ndcg_at_k(rel_ids, retrieved_ids, top_k)

        recall_scores.append(r_at_k)
        mrr_scores.append(mrr_score)
        ndcg_scores.append(ndcg_score)

        answer_text = None
        answer_rel = None
        faith = None

        if answerer is not None:
            context = _join_context([c.text for c in retrieved])
            answer_text = answerer.answer(query.question, context)
            if query.reference_answer:
                answer_rel = answer_similarity(answer_text, query.reference_answer, embedder)
                ans_rel_scores.append(answer_rel)
            faith = faithfulness(answer_text, context, embedder)
            faith_scores.append(faith)

        per_query.append(
            {
                "query_id": query.query_id,
                "question": query.question,
                "retrieved_chunk_ids": retrieved_ids,
                "recall@k": r_at_k,
                "mrr": mrr_score,
                "ndcg@k": ndcg_score,
                "answer": answer_text,
                "answer_similarity": answer_rel,
                "faithfulness": faith,
            }
        )

    metrics = {
        "recall@k": safe_mean(recall_scores),
        "mrr": safe_mean(mrr_scores),
        "ndcg@k": safe_mean(ndcg_scores),
        "answer_similarity": safe_mean(ans_rel_scores),
        "faithfulness": safe_mean(faith_scores),
    }

    return {
        "experiment": name,
        "metrics": metrics,
        "per_query": per_query,
    }
