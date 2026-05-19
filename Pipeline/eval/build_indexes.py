from __future__ import annotations

import argparse
import json
from pathlib import Path

from .chunk_prep import enrich_chunks
from .index_builder import build_index
from .utils import ensure_dir


def _load_config(path: Path) -> dict:
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def _resolve_path(base_dir: Path, value: str) -> Path:
    candidate = Path(value)
    if candidate.is_absolute():
        return candidate
    return (base_dir / candidate).resolve()


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

    registry_path = _resolve_path(base_dir, cfg["registry_path"])
    embed_cfg = cfg["embed"]

    for exp in cfg["experiments"]:
        source_dir = _resolve_path(base_dir, exp["source_chunks_dir"])
        enriched_dir = _resolve_path(base_dir, exp["enriched_output_dir"])
        index_db = _resolve_path(base_dir, exp["index_db_path"])

        ensure_dir(enriched_dir)
        ensure_dir(index_db.parent)

        print(f"\n[Prep] {exp['name']} -> {enriched_dir}")
        enrich_chunks(source_dir, registry_path, enriched_dir)

        print(f"[Index] {exp['name']} -> {index_db}")
        count = build_index(
            enriched_dir,
            index_db,
            embed_cfg["model_name"],
            embed_cfg["embed_dim"],
            embed_cfg["batch_size"],
        )
        print(f"[OK] {exp['name']} indexed {count} chunks")


if __name__ == "__main__":
    main()
