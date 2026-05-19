"""
enrich_chunks.py

Post-processing pass: joins neural chunks with registry.csv metadata
and extracts section headings from chunk text.

Run from DocumentsChunking/:
    python enrich_chunks.py

Input:  neural_chunks/*.json  +  registry.csv
Output: enriched_chunks/{doc_id}.json

Output schema per chunk:
    chunk_id        — "{doc_id}_c{index:03d}"  e.g. "ACS_CCFS_c002"
    doc_id          — from registry              e.g. "ACS_CCFS"
    text            — raw chunk text
    token_count     — from chunker
    section         — nearest preceding heading  e.g. "Risk Factors"
    page_start      — page number (if available)
    doc_type        — from registry              e.g. "guideline"
    source_org      — from registry              e.g. "ACS"
    credibility_tier — from registry             e.g. 1
"""

import csv
import json
import re
from pathlib import Path

REGISTRY_PATH = Path("registry.csv")
NEURAL_DIR = Path("neural_chunks")
OUTPUT_DIR = Path("enriched_chunks")
OUTPUT_DIR.mkdir(exist_ok=True)

# Matches any markdown heading line
_HEADING_RE = re.compile(r"^#{1,6}\s+(.+)", re.MULTILINE)
# Strips trailing citation markers like [ 1, 2] or (3, 4)
_CITATION_RE = re.compile(r"\s*[\[\(][\d,\s.\-]+[\]\)]\s*$")


def _extract_section(text: str, max_offset: int = 120) -> str | None:
    m = _HEADING_RE.search(text)
    if not m or m.start() > max_offset:
        return None
    heading = _CITATION_RE.sub("", m.group(1)).strip()
    return heading or None


def _extract_page_start(chunk: dict) -> int | None:
    for key in ("page_start", "page", "page_number"):
        value = chunk.get(key)
        if isinstance(value, int):
            return value
        if isinstance(value, str) and value.isdigit():
            return int(value)
    return None


def load_registry() -> dict[str, dict]:
    """Returns {title_stem: {doc_id, doc_type, source_org, credibility_tier}}."""
    result: dict[str, dict] = {}
    with open(REGISTRY_PATH, newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            tier_raw = row["credibility_tier"].strip()
            result[row["title"].strip()] = {
                "doc_id": row["doc_id"].strip(),
                "doc_type": row["doc_type"].strip(),
                "source_org": row["source_org"].strip(),
                "credibility_tier": int(tier_raw) if tier_raw.isdigit() else None,
            }
    return result


def enrich(registry: dict[str, dict]) -> None:
    files = sorted(NEURAL_DIR.glob("*.json"))
    if not files:
        print(f"[ERROR] No JSON files found in {NEURAL_DIR}/")
        return

    total_docs = total_chunks = 0

    for path in files:
        stem = path.stem
        if stem not in registry:
            print(f"[SKIP] {path.name} — title not in registry.csv")
            continue

        meta = registry[stem]
        doc_id = meta["doc_id"]

        with open(path, encoding="utf-8") as f:
            data = json.load(f)

        current_section: str | None = None
        enriched: list[dict] = []

        for chunk in data.get("chunks", []):
            found = _extract_section(chunk["text"])
            if found:
                current_section = found
            page_start = _extract_page_start(chunk)

            enriched.append(
                {
                    "chunk_id": f"{doc_id}_c{chunk['chunk_index']:03d}",
                    "doc_id": doc_id,
                    "text": chunk["text"],
                    "token_count": chunk.get("token_count"),
                    "section": current_section,
                    "page_start": page_start,
                    "doc_type": meta["doc_type"],
                    "source_org": meta["source_org"],
                    "credibility_tier": meta["credibility_tier"],
                }
            )

        output = {
            "doc_id": doc_id,
            "source_file": data["source_file"],
            "chunk_count": len(enriched),
            "chunks": enriched,
        }

        out_path = OUTPUT_DIR / f"{doc_id}.json"
        out_path.write_text(
            json.dumps(output, ensure_ascii=False, indent=2), encoding="utf-8"
        )

        total_docs += 1
        total_chunks += len(enriched)
        print(f"[OK] {stem} → {out_path.name}  ({len(enriched)} chunks)")

    print(f"\nDone: {total_docs} documents, {total_chunks} chunks total → {OUTPUT_DIR}/")


if __name__ == "__main__":
    enrich(load_registry())
