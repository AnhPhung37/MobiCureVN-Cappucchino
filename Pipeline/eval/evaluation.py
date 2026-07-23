"""
evaluation.py — Compare chunking, embedding model, retrieval mode, and top-k variants.

To add a new technique, append a Variant to VARIANTS below — nothing else to change.

Usage (from Pipeline/):
    python -m eval.evaluation
    python -m eval.evaluation --force-index   # rebuild all indexes even if they exist
    python -m eval.evaluation --only neural   # run only variants whose name contains "neural"
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path

from .dataset import load_qrels, load_queries, validate_dataset
from ..ingestion.build_index import build_index
from ..ingestion.enrich_chunks import enrich_source
from .retriever import Embedder, HybridRetriever, SQLiteVecRetriever
from .metrics_ir import mrr, ndcg_at_k, recall_at_k
from .metrics_qa import safe_mean
from .utils import ensure_dir, seed_everything, utc_now_compact, write_json

EVAL_DIR = Path(__file__).parent
PIPELINE_DIR = EVAL_DIR.parent

# ── Define variants here ───────────────────────────────────────────────────────
# Each Variant is one row in the results table.
# Variants sharing the same (chunks, embed_model) reuse the same index on disk.
#
# Fields:
#   name        — label shown in results table (keep it descriptive)
#   chunks      — name of the *_chunks/ dir under Pipeline/  e.g. "neural", "semantic"
#   embed_model — HuggingFace model ID
#   embed_dim   — must match the model's output dimension
#   mode        — "vector"  → KNN only
#                 "hybrid"  → KNN + FTS5 fused with RRF (mirrors the iOS app)
#   top_k       — number of chunks to retrieve per query

@dataclass(frozen=True)
class Variant:
    name: str
    chunks: str
    embed_model: str
    embed_dim: int
    mode: str
    top_k: int
    batch_size: int = 64

    @property
    def _model_slug(self) -> str:
        return self.embed_model.replace("/", "_").replace("-", "_").replace(".", "_")

    def source_chunks_dir(self) -> Path:
        return PIPELINE_DIR / "data" / f"{self.chunks}_chunks"

    def enriched_dir(self) -> Path:
        # Shared across variants with the same source chunks
        return EVAL_DIR / "outputs" / f"enriched_{self.chunks}"

    def index_path(self) -> Path:
        # Shared across variants with the same source chunks + embedding model
        return EVAL_DIR / "outputs" / f"index_{self.chunks}_{self._model_slug}.db"


VARIANTS: list[Variant] = [
    # ── Neural chunks ──────────────────────────────────────────────────────────
    Variant("neural · bge-small · vector · k=5",  "neural", "BAAI/bge-small-en-v1.5", 384, "vector", 5),
    Variant("neural · bge-small · vector · k=10", "neural", "BAAI/bge-small-en-v1.5", 384, "vector", 10),
    Variant("neural · bge-small · hybrid · k=5",  "neural", "BAAI/bge-small-en-v1.5", 384, "hybrid", 5),
    Variant("neural · bge-small · hybrid · k=10", "neural", "BAAI/bge-small-en-v1.5", 384, "hybrid", 10),

    # ── Semantic chunks ────────────────────────────────────────────────────────
    Variant("semantic · bge-small · vector · k=5",  "semantic", "BAAI/bge-small-en-v1.5", 384, "vector", 5),
    Variant("semantic · bge-small · vector · k=10", "semantic", "BAAI/bge-small-en-v1.5", 384, "vector", 10),
    Variant("semantic · bge-small · hybrid · k=5",  "semantic", "BAAI/bge-small-en-v1.5", 384, "hybrid", 5),

    # ── Larger embedding model (uncomment after downloading) ───────────────────
    # Variant("neural · bge-base · vector · k=5",    "neural", "BAAI/bge-base-en-v1.5",     768, "vector", 5),
    # Variant("neural · bge-base · hybrid · k=5",    "neural", "BAAI/bge-base-en-v1.5",     768, "hybrid", 5),

    # ── Lightweight model ──────────────────────────────────────────────────────
    # Variant("neural · potion-32M · vector · k=5",  "neural", "minishlab/potion-base-32M", 256, "vector", 5),
    # Variant("neural · potion-32M · hybrid · k=5",  "neural", "minishlab/potion-base-32M", 256, "hybrid", 5),
]
# ─────────────────────────────────────────────────────────────────────────────


def _build_retriever(variant: Variant, embedder: Embedder):
    db = variant.index_path()
    if variant.mode == "hybrid":
        return HybridRetriever(db, embedder)
    return SQLiteVecRetriever(db, embedder)


def _run_variant(variant: Variant, queries, qrels, embedder: Embedder) -> dict:
    retriever = _build_retriever(variant, embedder)

    recall_scores, mrr_scores, ndcg_scores = [], [], []
    per_query = []

    for query in queries:
        rel_ids = set(qrels[query.query_id].relevant_chunk_ids)
        retrieved = retriever.search(query.question, variant.top_k)
        retrieved_ids = [c.chunk_id for c in retrieved]

        r = recall_at_k(rel_ids, retrieved_ids, variant.top_k)
        m = mrr(rel_ids, retrieved_ids)
        n = ndcg_at_k(rel_ids, retrieved_ids, variant.top_k)

        recall_scores.append(r)
        mrr_scores.append(m)
        ndcg_scores.append(n)
        per_query.append({
            "query_id": query.query_id,
            "question": query.question,
            "retrieved_chunk_ids": retrieved_ids,
            "recall@k": r,
            "mrr": m,
            "ndcg@k": n,
        })

    return {
        "variant": variant.name,
        "config": {
            "chunks": variant.chunks,
            "embed_model": variant.embed_model,
            "mode": variant.mode,
            "top_k": variant.top_k,
        },
        "metrics": {
            "recall@k": safe_mean(recall_scores),
            "mrr": safe_mean(mrr_scores),
            "ndcg@k": safe_mean(ndcg_scores),
        },
        "per_query": per_query,
    }


def _print_table(results: list[dict]) -> None:
    col_w = max(len(r["variant"]) for r in results) + 2
    header = f"{'Variant':<{col_w}} {'Recall@K':>10} {'MRR':>8} {'NDCG@K':>8}"
    sep = "-" * len(header)
    print(f"\n{sep}")
    print(header)
    print(sep)
    for r in results:
        m = r["metrics"]
        print(
            f"{r['variant']:<{col_w}}"
            f" {m['recall@k']:>10.4f}"
            f" {m['mrr']:>8.4f}"
            f" {m['ndcg@k']:>8.4f}"
        )
    print(sep)


def main() -> None:
    parser = argparse.ArgumentParser(description="Sweep chunking/embedding/retrieval variants.")
    parser.add_argument("--force-index", action="store_true", help="Rebuild indexes even if they exist")
    parser.add_argument("--only", metavar="SUBSTR", help="Run only variants whose name contains SUBSTR")
    parser.add_argument("--seed", type=int, default=42)
    args = parser.parse_args()

    seed_everything(args.seed)

    queries = load_queries(EVAL_DIR / "data" / "queries.jsonl")
    qrels = load_qrels(EVAL_DIR / "data" / "qrels.jsonl")
    validate_dataset(queries, qrels)
    print(f"Dataset: {len(queries)} queries, {len(qrels)} qrels")

    variants = VARIANTS
    if args.only:
        variants = [v for v in VARIANTS if args.only in v.name]
        if not variants:
            raise SystemExit(f"No variants matched --only '{args.only}'")
        print(f"Running {len(variants)} matching variant(s)")

    registry_path = PIPELINE_DIR / "data" / "registry.csv"

    # Group variants by (chunks, embed_model) to share index-building work
    built_enriched: set[Path] = set()
    built_indexes: set[Path] = set()
    embedder_cache: dict[str, Embedder] = {}

    print("\n── Building indexes (skipped if already exist) ──")
    for v in variants:
        enriched_dir = v.enriched_dir()
        if enriched_dir not in built_enriched:
            if not any(enriched_dir.glob("*.json")):
                print(f"[Enrich] {v.chunks} → {enriched_dir.name}/")
                ensure_dir(enriched_dir)
                enrich_source(v.source_chunks_dir(), registry_path, enriched_dir)
            else:
                print(f"[Skip enrich] {enriched_dir.name}/ already populated")
            built_enriched.add(enriched_dir)

        index_path = v.index_path()
        if index_path not in built_indexes:
            if index_path.exists() and not args.force_index:
                print(f"[Skip index] {index_path.name} already exists")
            else:
                print(f"[Index] {index_path.name} ({v.embed_model})")
                ensure_dir(index_path.parent)
                build_index(enriched_dir, index_path, v.embed_model, v.embed_dim, v.batch_size)
            built_indexes.add(index_path)

        if v.embed_model not in embedder_cache:
            embedder_cache[v.embed_model] = Embedder(v.embed_model, batch_size=v.batch_size)

    print("\n── Evaluating variants ──")
    results = []
    for v in variants:
        print(f"[Eval] {v.name} ...")
        embedder = embedder_cache[v.embed_model]
        result = _run_variant(v, queries, qrels, embedder)
        results.append(result)
        m = result["metrics"]
        print(f"       recall@{v.top_k}={m['recall@k']:.4f}  mrr={m['mrr']:.4f}  ndcg@{v.top_k}={m['ndcg@k']:.4f}")

    _print_table(results)

    results_dir = EVAL_DIR / "results"
    ensure_dir(results_dir)
    out_path = results_dir / f"sweep_{utc_now_compact()}.json"
    write_json(out_path, {"variants": results})
    print(f"\nFull results → {out_path}")


if __name__ == "__main__":
    main()
