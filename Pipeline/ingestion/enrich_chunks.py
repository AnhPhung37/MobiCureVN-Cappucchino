"""
enrich_chunks.py — Stage 4: Enrich chunks with registry metadata

Joins chunked JSON with registry.csv metadata and extracts section headings.

Input:  neural_chunks/*.json  (or semantic_chunks/ with --chunker semantic)
        registry.csv
Output: enriched_chunks/{doc_id}.json

Output schema per chunk:
    chunk_id         — "{doc_id}_c{index:03d}"  e.g. "ACS_CCFS_c002"
    doc_id           — from registry              e.g. "ACS_CCFS"
    text             — raw chunk text
    token_count      — from chunker
    section          — nearest preceding heading  e.g. "Risk Factors"
    page_start       — page number (if available)
    doc_type         — from registry              e.g. "guideline"
    source_org       — from registry              e.g. "ACS"
    credibility_tier — from registry              e.g. 1

Usage:
    python enrich_chunks.py
    python enrich_chunks.py --chunker semantic
    python enrich_chunks.py --force
"""
from __future__ import annotations

import argparse
import csv
import json
import re
from pathlib import Path

_ROOT = Path(__file__).parent.parent
REGISTRY_PATH = _ROOT / "data" / "registry.csv"
NEURAL_DIR = _ROOT / "data" / "neural_chunks"
SEMANTIC_DIR = _ROOT / "data" / "semantic_chunks"
OUTPUT_DIR = _ROOT / "data" / "enriched_chunks"

_HEADING_RE = re.compile(r"^#{1,6}\s+(.+)", re.MULTILINE)
_CITATION_RE = re.compile(r"\s*[\[\(][\d,\s.\-]+[\]\)]\s*$")


def _extract_section(text: str, max_offset: int = 120) -> str | None:
    m = _HEADING_RE.search(text)
    if not m or m.start() > max_offset:
        return None
    heading = _CITATION_RE.sub("", m.group(1)).strip()
    if not heading or len(heading) < 3 or (len(heading.split()) == 1 and len(heading) < 5):
        return None
    return heading


def _extract_page_start(chunk: dict) -> int | None:
    for key in ("page_start", "page", "page_number"):
        value = chunk.get(key)
        if isinstance(value, int):
            return value
        if isinstance(value, str) and value.isdigit():
            return int(value)
    return None


def load_registry(registry_path: Path = REGISTRY_PATH) -> dict[str, dict]:
    result: dict[str, dict] = {}
    with open(registry_path, newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            tier_raw = row["credibility_tier"].strip()
            result[row["title"].strip()] = {
                "doc_id": row["doc_id"].strip(),
                "doc_type": row["doc_type"].strip(),
                "source_org": row["source_org"].strip(),
                "credibility_tier": int(tier_raw) if tier_raw.isdigit() else None,
            }
    return result


def enrich_source(source_dir: Path, registry_path: Path, output_dir: Path, force: bool = False) -> int:
    """Enrich all chunk JSONs in source_dir and write to output_dir. Returns chunk count."""
    output_dir.mkdir(parents=True, exist_ok=True)
    registry = load_registry(registry_path)

    files = sorted(source_dir.glob("*.json"))
    if not files:
        print(f"[WARN] No JSON files in {source_dir.name}/ — run chunk.py first")
        return 0

    total_docs = total_chunks = 0

    for path in files:
        stem = path.stem
        if stem not in registry:
            print(f"[SKIP] {path.name} — title not in registry.csv")
            continue

        meta = registry[stem]
        doc_id = meta["doc_id"]
        out_path = output_dir / f"{doc_id}.json"

        if out_path.exists() and not force:
            print(f"[SKIP] {path.name} — already enriched (use --force to rebuild)")
            continue

        data = json.loads(path.read_text(encoding="utf-8"))

        current_section: str | None = None
        enriched: list[dict] = []

        for chunk in data.get("chunks", []):
            found = _extract_section(chunk["text"])
            if found:
                current_section = found

            enriched.append({
                "chunk_id": f"{doc_id}_c{chunk['chunk_index']:03d}",
                "doc_id": doc_id,
                "text": chunk["text"],
                "token_count": chunk.get("token_count"),
                "section": current_section,
                "page_start": _extract_page_start(chunk),
                "doc_type": meta["doc_type"],
                "source_org": meta["source_org"],
                "credibility_tier": meta["credibility_tier"],
            })

        output = {
            "doc_id": doc_id,
            "source_file": data["source_file"],
            "chunk_count": len(enriched),
            "chunks": enriched,
        }
        out_path.write_text(json.dumps(output, ensure_ascii=False, indent=2), encoding="utf-8")

        total_docs += 1
        total_chunks += len(enriched)
        print(f"[OK]   {stem} → {out_path.name}  ({len(enriched)} chunks)")

    print(f"\nDone: {total_docs} documents, {total_chunks} chunks total → {output_dir.name}/")
    return total_chunks


def main(chunker: str, force: bool) -> None:
    source_dir = NEURAL_DIR if chunker == "neural" else SEMANTIC_DIR
    enrich_source(source_dir, REGISTRY_PATH, OUTPUT_DIR, force)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Stage 4: Enrich chunks with registry metadata.")
    parser.add_argument(
        "--chunker",
        choices=["neural", "semantic"],
        default="neural",
        help="Source chunks directory (default: neural)",
    )
    parser.add_argument("--force", action="store_true", help="Rebuild even if output exists")
    args = parser.parse_args()
    main(args.chunker, args.force)
