from __future__ import annotations

import argparse
import json
from pathlib import Path

from ingestion.contextual_header import load_titles

from .chunk_prep import enrich_chunks
from .index_builder import build_index
from .provenance import index_fingerprint
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

    built: set[Path] = set()
    for exp in cfg["experiments"]:
        if not exp.get("enabled", True):
            print(f"[SKIP] {exp['name']}: {exp.get('disabled_reason', 'disabled in config')}")
            continue
        if _resolve_path(base_dir, exp["index_db_path"]) in built:
            # Several experiments may score one index with different retrieval settings.
            print(f"[SKIP] {exp['name']}: index already built above")
            continue
        built.add(_resolve_path(base_dir, exp["index_db_path"]))

        source_dir = _resolve_path(base_dir, exp["source_chunks_dir"])
        enriched_dir = _resolve_path(base_dir, exp["enriched_output_dir"])
        index_db = _resolve_path(base_dir, exp["index_db_path"])

        ensure_dir(enriched_dir)
        ensure_dir(index_db.parent)

        print(f"\n[Prep] {exp['name']} -> {enriched_dir}")
        enrich_chunks(source_dir, registry_path, enriched_dir)

        # An experiment may switch on the contextual header for its own index. Nothing else in
        # `embed` may differ per experiment: run_eval embeds every query with the shared model.
        overrides = exp.get("embed", {})
        if set(overrides) - {"contextual_header"}:
            raise SystemExit(f"{exp['name']}: only embed.contextual_header may be set per experiment")
        titles = load_titles(registry_path) if overrides.get("contextual_header") else None

        print(f"[Index] {exp['name']} -> {index_db}" + (" (contextual header)" if titles else ""))
        count = build_index(
            enriched_dir,
            index_db,
            embed_cfg["model_name"],
            embed_cfg["embed_dim"],
            embed_cfg["batch_size"],
            titles=titles,
        )
        fp = index_fingerprint(index_db)
        print(
            f"[OK] {exp['name']} indexed {count} chunks "
            f"({fp['doc_count']} docs, sha256={(fp['sha256'] or '')[:12]})"
        )


if __name__ == "__main__":
    main()
