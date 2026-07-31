"""
ab_retrieval.py — A/B sweep of retrieval variants through the golden eval.

Compares the shipped hybrid config against candidate tweaks (always-fuse the
vector pass, drop stopwords from the FTS query, longer min token length) using
the same 209-query golden set and the eval index. Reports recall@5 / MRR /
nDCG@5 (exact chunk) plus doc-hit@5 (retrieved a chunk from the right document).
"""
from __future__ import annotations

from pathlib import Path

from eval.dataset import load_queries, load_qrels
from eval.metrics_ir import mrr, ndcg_at_k, recall_at_k
from eval.retriever import Embedder, HybridRetriever, SQLiteVecRetriever

ROOT = Path(__file__).parent.parent
DB = ROOT / "eval" / "outputs" / "vectorstore_neural.db"
TOP_K = 5


def doc(chunk_id: str) -> str:
    return chunk_id.rsplit("_c", 1)[0]


def evaluate(retriever, queries, qrels) -> dict:
    rec, mr, nd, dh = [], [], [], []
    for q in queries:
        gold = set(qrels[q.query_id].relevant_chunk_ids)
        gold_docs = {doc(g) for g in gold}
        got = [c.chunk_id for c in retriever.search(q.question, TOP_K)]
        rec.append(recall_at_k(gold, got, TOP_K))
        mr.append(mrr(gold, got))
        nd.append(ndcg_at_k(gold, got, TOP_K))
        dh.append(1.0 if gold_docs & {doc(c) for c in got} else 0.0)
    n = len(queries)
    return {
        "recall@5": sum(rec) / n,
        "mrr": sum(mr) / n,
        "ndcg@5": sum(nd) / n,
        "doc-hit@5": sum(dh) / n,
    }


def main() -> None:
    queries = load_queries(ROOT / "eval" / "data" / "queries.jsonl")
    qrels = load_qrels(ROOT / "eval" / "data" / "qrels.jsonl")
    embedder = Embedder("BAAI/bge-small-en-v1.5")

    variants: dict[str, object] = {
        "vector-only": SQLiteVecRetriever(DB, embedder),
        "hybrid (ships)": HybridRetriever(DB, embedder),
        "hybrid +always_fuse": HybridRetriever(DB, embedder, always_fuse=True),
        "hybrid +drop_stopwords": HybridRetriever(DB, embedder, drop_stopwords=True),
        "hybrid +fuse +stopwords": HybridRetriever(DB, embedder, always_fuse=True, drop_stopwords=True),
        "hybrid +fuse +stop +mintok5": HybridRetriever(
            DB, embedder, always_fuse=True, drop_stopwords=True, min_token_length=5
        ),
    }

    print(f"{'variant':<30}{'recall@5':>10}{'mrr':>8}{'ndcg@5':>9}{'doc-hit@5':>11}")
    print("-" * 68)
    for name, r in variants.items():
        m = evaluate(r, queries, qrels)
        print(
            f"{name:<30}{m['recall@5']:>10.3f}{m['mrr']:>8.3f}{m['ndcg@5']:>9.3f}{m['doc-hit@5']:>11.3f}"
        )


if __name__ == "__main__":
    main()
