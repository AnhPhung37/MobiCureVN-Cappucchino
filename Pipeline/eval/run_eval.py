from __future__ import annotations

import argparse
import json
from pathlib import Path

from .dataset import load_qrels, load_queries, validate_dataset
from .provenance import (
    app_retrieval,
    config_digest,
    repo_relative,
    corpus_fingerprint,
    environment,
    git_state,
    index_fingerprint,
    qrels_coverage,
)
from .llm_clients import OllamaAnswerer, OllamaConfig, OpenAICompatibleAnswerer, OpenAICompatibleConfig
from .retriever import Embedder
from .runner import run_experiment
from .utils import ensure_dir, seed_everything, utc_now_compact, write_json


def _load_config(path: Path) -> dict:
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def _resolve_path(base_dir: Path, value: str) -> Path:
    candidate = Path(value)
    if candidate.is_absolute():
        return candidate
    return (base_dir / candidate).resolve()


def _build_answerer(cfg: dict | None):
    if not cfg or cfg.get("type") == "none":
        return None
    if cfg["type"] == "openai_compatible":
        return OpenAICompatibleAnswerer(
            OpenAICompatibleConfig(
                base_url=cfg["base_url"],
                model=cfg["model"],
                api_key=cfg.get("api_key"),
                timeout_s=cfg.get("timeout_s", 120),
            )
        )
    if cfg["type"] == "ollama":
        return OllamaAnswerer(
            OllamaConfig(
                base_url=cfg["base_url"],
                model=cfg["model"],
                timeout_s=cfg.get("timeout_s", 120),
            )
        )
    raise ValueError(f"Unknown answerer type: {cfg.get('type')}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--config",
        type=Path,
        default=Path(__file__).with_name("experiment_config.json"),
        help="Path to experiment_config.json",
    )
    args = parser.parse_args()

    cfg = _load_config(args.config)
    base_dir = args.config.parent

    seed_everything(cfg["evaluation"]["seed"])

    queries = load_queries(_resolve_path(base_dir, cfg["evaluation"]["queries_path"]))
    qrels = load_qrels(_resolve_path(base_dir, cfg["evaluation"]["qrels_path"]))
    validate_dataset(queries, qrels)

    embed_cfg = cfg["embed"]
    embedder = Embedder(embed_cfg["model_name"], batch_size=embed_cfg["batch_size"])

    answerer = _build_answerer(cfg.get("answerer"))

    repo_dir = base_dir.parent.parent

    results = {
        "config": cfg,
        "config_sha256": config_digest(cfg),
        "generated_at": utc_now_compact(),
        "git": git_state(repo_dir),
        "app_retrieval": app_retrieval(repo_dir),
        "environment": environment(),
        "dataset": {
            "queries_path": repo_relative(_resolve_path(base_dir, cfg["evaluation"]["queries_path"]), repo_dir),
            "qrels_path": repo_relative(_resolve_path(base_dir, cfg["evaluation"]["qrels_path"]), repo_dir),
            "query_count": len(queries),
            "qrel_count": len(qrels),
        },
        "experiments": [],
    }

    for exp in cfg["experiments"]:
        if not exp.get("enabled", True):
            print(f"[SKIP] {exp['name']}: {exp.get('disabled_reason', 'disabled in config')}")
            continue

        # An experiment may override retrieval keys (e.g. mode) on top of the shared block.
        retrieval = {**cfg.get("retrieval", {}), **exp.get("retrieval", {})}
        if exp.get("represents_app") and retrieval.get("mode", "hybrid") != results["app_retrieval"]["mode"]:
            print(
                f"[WARN] {exp['name']} is marked as the app's retriever but scores mode="
                f"{retrieval.get('mode', 'hybrid')!r}; a build of this tree ships "
                f"{results['app_retrieval']['mode']!r} (query embedder bundled: "
                f"{results['app_retrieval']['query_embedder_bundled']})."
            )

        db_path = _resolve_path(base_dir, exp["index_db_path"])
        source_dir = _resolve_path(base_dir, exp["source_chunks_dir"])
        coverage = qrels_coverage(qrels, db_path)

        # A golden set the index cannot answer caps recall at `coverage`. Say so
        # loudly at run time rather than letting a plumbing bug read as a bad
        # retriever -- that is the mistake this harness already made once.
        if coverage["coverage"] is not None and coverage["coverage"] < 0.99:
            print(
                f"[WARN] {exp['name']}: only {coverage['present_in_index']}/"
                f"{coverage['gold_chunk_ids']} gold chunks are in {db_path.name} "
                f"(coverage {coverage['coverage']:.3f}). recall@k cannot exceed that. "
                f"Rebuild the index from {source_dir} before trusting these numbers."
            )

        result = run_experiment(
            name=exp["name"],
            db_path=db_path,
            queries=queries,
            qrels=qrels,
            embedder=embedder,
            top_k=cfg["evaluation"]["top_k"],
            answerer=answerer,
            retrieval=retrieval,
        )
        index = index_fingerprint(db_path)
        index["path"] = repo_relative(db_path, repo_dir)
        corpus = corpus_fingerprint(source_dir)
        corpus["path"] = repo_relative(source_dir, repo_dir)
        # Per-experiment embedding switches (build_indexes honours embed.contextual_header), so a
        # result says which document embeddings it scored.
        result["embed_overrides"] = exp.get("embed", {})
        result["provenance"] = {
            "index": index,
            "corpus": corpus,
            "qrels_coverage": coverage,
        }
        results["experiments"].append(result)

    if not results["experiments"]:
        raise SystemExit("No enabled experiments in config -- nothing was evaluated.")

    results_dir = _resolve_path(base_dir, cfg["evaluation"].get("results_dir", "./results"))
    ensure_dir(results_dir)
    out_path = results_dir / f"eval_{results['generated_at']}.json"
    write_json(out_path, results)

    for exp in results["experiments"]:
        m = exp["metrics"]
        prov = exp["provenance"]
        print(
            f"\n[{exp['experiment']} | {exp['retrieval']['mode']}] "
            f"recall@k={m['recall@k']:.4f} doc_hit@k={m['doc_hit@k']:.4f} "
            f"mrr={m['mrr']:.4f} ndcg@k={m['ndcg@k']:.4f}"
        )
        print(
            f"  index={prov['index']['chunk_count']} chunks / "
            f"{prov['index']['doc_count']} docs, sha256={(prov['index']['sha256'] or '')[:12]}"
        )
        print(f"  gold-chunk coverage={prov['qrels_coverage']['coverage']}")
    print(f"\nWrote results to {out_path}")


if __name__ == "__main__":
    main()
