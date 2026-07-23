from __future__ import annotations

import argparse
import json
from pathlib import Path

from .dataset import load_qrels, load_queries, validate_dataset
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

    results = {
        "config": cfg,
        "experiments": [],
    }

    for exp in cfg["experiments"]:
        result = run_experiment(
            name=exp["name"],
            db_path=_resolve_path(base_dir, exp["index_db_path"]),
            queries=queries,
            qrels=qrels,
            embedder=embedder,
            top_k=cfg["evaluation"]["top_k"],
            answerer=answerer,
            retrieval=cfg.get("retrieval"),
        )
        results["experiments"].append(result)

    results_dir = _resolve_path(base_dir, cfg["evaluation"].get("results_dir", "./results"))
    ensure_dir(results_dir)
    out_path = results_dir / f"eval_{utc_now_compact()}.json"
    write_json(out_path, results)
    print(f"Wrote results to {out_path}")


if __name__ == "__main__":
    main()
