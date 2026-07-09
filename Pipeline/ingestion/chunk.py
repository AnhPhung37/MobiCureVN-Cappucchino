"""
chunk.py — Stage 3: Chunk cleaned Markdown

Input:  cleaned_markdowns/*.md
Output: neural_chunks/*.json  and/or  semantic_chunks/*.json

Usage:
    python chunk.py
    python chunk.py --chunker semantic
    python chunk.py --chunker both
    python chunk.py --force
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

_ROOT = Path(__file__).parent.parent
CLEANED_DIR = _ROOT / "data" / "cleaned_markdowns"
NEURAL_DIR = _ROOT / "data" / "neural_chunks"
SEMANTIC_DIR = _ROOT / "data" / "semantic_chunks"

MIN_CHUNK_TOKENS = 15


def _serialize_chunk(chunk, index: int) -> dict:
    return {
        "chunk_index": index,
        "text": chunk.text,
        "token_count": getattr(chunk, "token_count", None),
    }


def chunk_neural(force: bool) -> None:
    from chonkie import NeuralChunker

    NEURAL_DIR.mkdir(exist_ok=True)
    mds = sorted(CLEANED_DIR.glob("*.md"))
    if not mds:
        print("[WARN] No cleaned markdown files — run clean.py first")
        return

    print("Loading NeuralChunker...")
    try:
        chunker = NeuralChunker(
            model="mirth/chonky_modernbert_base_1",
            min_characters_per_chunk=10,
        )
    except Exception as exc:
        print(f"[FAIL] NeuralChunker init failed: {exc}")
        return

    for path in mds:
        out = NEURAL_DIR / f"{path.stem}.json"
        if out.exists() and not force:
            print(f"[SKIP] {path.name} — neural chunks already exist")
            continue
        try:
            text = path.read_text(encoding="utf-8")
            chunks = chunker(text) if callable(chunker) else chunker.chunk(text)
            chunks = [c for c in chunks if (getattr(c, "token_count", None) or len(c.text.split())) >= MIN_CHUNK_TOKENS]
            payload = {
                "source_file": path.name,
                "source_path": str(path),
                "chunker": "NeuralChunker",
                "model": "mirth/chonky_modernbert_base_1",
                "chunk_count": len(chunks),
                "chunks": [_serialize_chunk(c, i) for i, c in enumerate(chunks, start=1)],
            }
            out.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
            print(f"[OK]   {path.name} → {out.name} ({len(chunks)} chunks)")
        except Exception as exc:
            print(f"[FAIL] {path.name}: {exc}")


def chunk_semantic(force: bool) -> None:
    from chonkie import OverlapRefinery, Pipeline
    from chonkie.types import RecursiveLevel, RecursiveRules

    SEMANTIC_DIR.mkdir(exist_ok=True)
    mds = sorted(CLEANED_DIR.glob("*.md"))
    if not mds:
        print("[WARN] No cleaned markdown files — run clean.py first")
        return

    rules = RecursiveRules(
        levels=[
            RecursiveLevel(delimiters=["\n\n"], include_delim="prev"),
            RecursiveLevel(delimiters=[". ", "! ", "? "], include_delim="prev"),
        ]
    )

    for path in mds:
        out = SEMANTIC_DIR / f"{path.stem}.json"
        if out.exists() and not force:
            print(f"[SKIP] {path.name} — semantic chunks already exist")
            continue
        try:
            doc = (
                Pipeline()
                .fetch_from("file", path=str(path))
                .process_with("markdown")
                .chunk_with(
                    "semantic",
                    threshold=0.7,
                    chunk_size=500,
                    similarity_window=6,
                    skip_window=0,
                    min_sentences_per_chunk=2,
                    delim=[". ", "!", "?", "\n\n", "#", "##", "###", "####"],
                )
                .refine_with(
                    "overlap",
                    tokenizer="word",
                    context_size=0.12,
                    mode="recursive",
                    method="prefix",
                    rules=rules,
                    merge=True,
                    inplace=True,
                )
                .refine_with("embeddings", embedding_model="minishlab/potion-base-32M")
                .run()
            )
            chunks = [c for c in doc.chunks if (getattr(c, "token_count", None) or len(c.text.split())) >= MIN_CHUNK_TOKENS]
            payload = {
                "source_file": path.name,
                "source_path": str(path),
                "chunker": "semantic",
                "chunk_count": len(chunks),
                "chunks": [_serialize_chunk(c, i) for i, c in enumerate(chunks, start=1)],
            }
            out.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
            print(f"[OK]   {path.name} → {out.name} ({len(chunks)} chunks)")
        except Exception as exc:
            print(f"[FAIL] {path.name}: {exc}")


def main(chunker: str, force: bool) -> None:
    if chunker in ("neural", "both"):
        print("=== Neural Chunking ===")
        chunk_neural(force)
    if chunker in ("semantic", "both"):
        print("=== Semantic Chunking ===")
        chunk_semantic(force)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Stage 3: Chunk cleaned Markdown.")
    parser.add_argument(
        "--chunker",
        choices=["neural", "semantic", "both"],
        default="neural",
        help="Chunking strategy (default: neural)",
    )
    parser.add_argument("--force", action="store_true", help="Rebuild even if output exists")
    args = parser.parse_args()
    main(args.chunker, args.force)
