from __future__ import annotations

import csv
import json
import re
from pathlib import Path


_HEADING_RE = re.compile(r"^#{1,6}\s+(.+)", re.MULTILINE)
_CITATION_RE = re.compile(r"\s*[\[\(][\d,\s.\-]+[\]\)]\s*$")


def _extract_section(text: str) -> str | None:
    m = _HEADING_RE.search(text)
    if not m:
        return None
    heading = _CITATION_RE.sub("", m.group(1)).strip()
    return heading or None


def load_registry(registry_path: Path) -> dict[str, dict]:
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


def enrich_chunks(
    source_dir: Path, registry_path: Path, output_dir: Path
) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    registry = load_registry(registry_path)

    files = sorted(source_dir.glob("*.json"))
    if not files:
        raise FileNotFoundError(f"No JSON files found in {source_dir}")

    for path in files:
        stem = path.stem
        if stem not in registry:
            print(f"[SKIP] {path.name} - title not in registry.csv")
            continue

        meta = registry[stem]
        doc_id = meta["doc_id"]

        with open(path, encoding="utf-8") as f:
            data = json.load(f)

        current_section: str | None = None
        enriched: list[dict] = []

        for chunk in data.get("chunks", []):
            found = _extract_section(chunk.get("text", ""))
            if found:
                current_section = found

            enriched.append(
                {
                    "chunk_id": f"{doc_id}_c{chunk['chunk_index']:03d}",
                    "doc_id": doc_id,
                    "text": chunk.get("text", ""),
                    "token_count": chunk.get("token_count"),
                    "section": current_section,
                    "doc_type": meta["doc_type"],
                    "source_org": meta["source_org"],
                    "credibility_tier": meta["credibility_tier"],
                }
            )

        output = {
            "doc_id": doc_id,
            "source_file": data.get("source_file"),
            "chunk_count": len(enriched),
            "chunks": enriched,
        }

        out_path = output_dir / f"{doc_id}.json"
        out_path.write_text(
            json.dumps(output, ensure_ascii=False, indent=2), encoding="utf-8"
        )
        print(f"[OK] {path.name} -> {out_path.name} ({len(enriched)} chunks)")
