"""
run_pipeline.py — Full ingestion pipeline: PDF → vectorstore.db

Stages (run in order unless --stages is specified):
  parse   PDF → parsed_markdowns/
  clean   parsed_markdowns/ → cleaned_markdowns/
  chunk   cleaned_markdowns/ → neural_chunks/ and/or semantic_chunks/
  enrich  {chunker}_chunks/ → enriched_chunks/
  index   enriched_chunks/ → vectorstore.db

Usage (from Pipeline/):
  python run_pipeline.py
  python run_pipeline.py --chunker semantic
  python run_pipeline.py --chunker both
  python run_pipeline.py --stages parse clean         # only first two stages
  python run_pipeline.py --force                      # rebuild everything
  python run_pipeline.py --force --stages chunk index # rebuild only these two
"""

from __future__ import annotations

import argparse
import csv
import json
import re
import struct
import sys
from collections import Counter
from pathlib import Path

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
BASE_DIR = Path(__file__).parent
PDF_DIR = BASE_DIR / "raw_pdfs"
PARSED_DIR = BASE_DIR / "parsed_markdowns"
CLEANED_DIR = BASE_DIR / "cleaned_markdowns"
NEURAL_DIR = BASE_DIR / "neural_chunks"
SEMANTIC_DIR = BASE_DIR / "semantic_chunks"
ENRICHED_DIR = BASE_DIR / "enriched_chunks"
DB_PATH = BASE_DIR / "vectorstore.db"
REGISTRY_PATH = BASE_DIR / "registry.csv"

EMBED_MODEL = "BAAI/bge-small-en-v1.5"
EMBED_DIM = 384
BATCH_SIZE = 64
MIN_CHUNK_TOKENS = 15  # discard near-empty chunks

# ---------------------------------------------------------------------------
# Stage 1: Parse PDF → Markdown
# ---------------------------------------------------------------------------

_FAULTY_PDFS: set[str] = {
    "Bowel_Cancer_UK_Colonic_Stenting_V2.1",  # manually parsed; already in cleaned_markdowns
}


def stage_parse(force: bool) -> None:
    import pymupdf4llm

    PARSED_DIR.mkdir(exist_ok=True)
    pdfs = sorted(PDF_DIR.glob("*.pdf"))
    if not pdfs:
        print("[WARN] No PDFs found in raw_pdfs/")
        return

    for pdf in pdfs:
        stem = pdf.stem
        out = PARSED_DIR / f"{stem}.md"
        if stem in _FAULTY_PDFS:
            print(f"[SKIP] {pdf.name} — manually parsed, skipping")
            continue
        if out.exists() and not force:
            print(f"[SKIP] {pdf.name} — already parsed (use --force to rebuild)")
            continue
        try:
            md = pymupdf4llm.to_markdown(str(pdf))
            out.write_text(md, encoding="utf-8")
            print(f"[OK]   {pdf.name} → {out.name}")
        except Exception as exc:
            print(f"[FAIL] {pdf.name}: {exc}")


# ---------------------------------------------------------------------------
# Stage 2: Clean Markdown
# ---------------------------------------------------------------------------

_HEADING_RE = re.compile(r"^\s*#{1,6}\s+")
_LIST_RE = re.compile(r"^\s*([*\-]|\d+\.)\s+")
_BLANK_RE = re.compile(r"^\s*$")
_TABLE_ROW_RE = re.compile(r"^\s*\|.*\|\s*$")
_TABLE_SEP_RE = re.compile(r"^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)+\|?\s*$")
_SENTENCE_END_RE = re.compile(r"[.!?:]\s*$")
_LOWER_START_RE = re.compile(r"^[a-z(\[\{\)\]\}]")
_DOWNLOAD_URL_RE = re.compile(r"Downloaded from https?://", re.IGNORECASE)
_HEADING_NORM_RE = re.compile(r"^\s*(#{1,6})\s+(.*)")


def _is_table_line(line: str) -> bool:
    return bool(_TABLE_ROW_RE.match(line) or _TABLE_SEP_RE.match(line))


def _is_protected(line: str) -> bool:
    return bool(_BLANK_RE.match(line) or _LIST_RE.match(line) or _is_table_line(line))


def _detect_repeating_lines(text: str, min_length: int = 5, freq_threshold: float = 0.02) -> set[str]:
    raw_lines = [l.strip() for l in text.split("\n")]
    filtered = [l for l in raw_lines if len(l) >= min_length and not _is_protected(l)]
    total = len(filtered)
    if total == 0:
        return set()
    counter = Counter(filtered)
    return {line for line, count in counter.items() if count > 2 and count / total >= freq_threshold}


def _normalize_whitespace(text: str) -> str:
    text = re.sub(r"^[ \t]+", "", text, flags=re.MULTILINE)
    text = re.sub(r"[ \t]+$", "", text, flags=re.MULTILINE)
    text = re.sub(r"[ ]{2,}", " ", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text


def _remove_bold_asterisks(text: str) -> str:
    return re.sub(r"\*\*(.*?)\*\*", r"\1", text)


def _fix_broken_words(text: str) -> str:
    text = re.sub(r"(\w+)-\n(\w+)", r"\1\2", text)
    text = re.sub(r"([a-zA-Z0-9]+)\s+(-\w+)", r"\1\2", text)
    return text


def _normalize_bullets(text: str) -> str:
    return re.sub(r"^\s*#*\s*([•▪◦●○]|(`o`))+\s*", "\n- ", text, flags=re.MULTILINE)


def _remove_download_urls(text: str) -> str:
    lines = [l for l in text.split("\n") if not _DOWNLOAD_URL_RE.search(l)]
    return "\n".join(lines)


def _merge_lines(text: str) -> str:
    lines = text.split("\n")
    merged: list[str] = []
    in_table = False
    i = 0

    while i < len(lines):
        line = lines[i]
        stripped = line.strip()

        if _is_table_line(line):
            merged.append(line)
            in_table = True
            i += 1
            continue
        else:
            in_table = False

        if re.match(r"\s*---\s*", line):
            i += 1
            continue

        if _BLANK_RE.match(line):
            if merged:
                prev = merged[-1]
                j = i + 1
                while j < len(lines) and _BLANK_RE.match(lines[j]):
                    j += 1
                nxt = lines[j].strip() if j < len(lines) else ""
                if j < len(lines) and not _SENTENCE_END_RE.search(prev) and _LOWER_START_RE.match(nxt):
                    i += 1
                    continue
                if _LIST_RE.match(prev) and _LIST_RE.match(nxt):
                    i += 1
                    continue
            if not merged or merged[-1] != "":
                merged.append("")
            i += 1
            continue

        if _HEADING_RE.match(line):
            merged.append(stripped)
            i += 1
            continue

        if _LIST_RE.match(line):
            merged.append(stripped)
            i += 1
            continue

        if merged:
            prev = merged[-1]
            if _is_table_line(prev):
                merged.append(stripped)
                i += 1
                continue
            if _LIST_RE.match(prev):
                merged[-1] = prev + " " + stripped
                i += 1
                continue
            if not _HEADING_RE.match(prev) and not _SENTENCE_END_RE.search(prev) and _LOWER_START_RE.match(stripped):
                merged[-1] = prev + " " + stripped
                i += 1
                continue

        merged.append(stripped)
        i += 1

    return "\n".join(merged)


def _clean_and_normalize_headings(text: str) -> str:
    MAX_HEADER_WORDS = 10
    lines = text.split("\n")
    out: list[str] = []
    seen: set[str] = set()
    prev_level = 0
    i = 0

    while i < len(lines):
        line = lines[i].strip()
        m = _HEADING_NORM_RE.match(line)
        if not m:
            out.append(lines[i])
            i += 1
            continue

        hashes, content = m.groups()
        combined = content
        j = i + 1
        while j < len(lines):
            nxt = lines[j].strip()
            nm = _HEADING_NORM_RE.match(nxt)
            if nm:
                combined += " " + nm.group(2)
                j += 1
            elif nxt and len(nxt.split()) <= 6:
                combined += " " + nxt
                j += 1
            else:
                break

        words = combined.split()
        has_content = any(
            lines[k].strip() and not _HEADING_NORM_RE.match(lines[k].strip())
            for k in range(j, len(lines))
            if not _HEADING_NORM_RE.match(lines[k].strip())
        )

        if len(words) > MAX_HEADER_WORDS or not has_content:
            out.append(combined)
            i = j
            continue

        lvl = len(hashes)
        key = combined.lower().strip()

        if prev_level and lvl > prev_level + 1:
            lvl = prev_level + 1
        if key in seen:
            lvl = min(lvl + 1, 6)
        else:
            seen.add(key)
        if lvl == 1 and prev_level != 0:
            lvl = 2

        out.append("#" * lvl + " " + combined.strip())
        prev_level = lvl
        i = j

    return "\n".join(out)


def _remove_headers_footers(text: str) -> str:
    lines = text.split("\n")
    cleaned = []
    for line in lines:
        # Page numbers: standalone digit lines (surrounded by whitespace, optionally bold)
        if re.match(r"^\s*(\*\*)?\d{1,3}(\*\*)?\s*$", line):
            continue
        if len(line.strip()) < 3:
            cleaned.append(line)
            continue
        if line.isupper() and len(line.split()) > 5:
            continue
        cleaned.append(line)
    return "\n".join(cleaned)


def _remove_repeating_lines(text: str) -> str:
    repeating = _detect_repeating_lines(text)
    return "\n".join(l for l in text.split("\n") if l.strip() not in repeating)


def _clean_text(text: str) -> str:
    text = _normalize_whitespace(text)
    text = _remove_bold_asterisks(text)
    text = _fix_broken_words(text)
    text = _normalize_bullets(text)
    text = _remove_download_urls(text)
    text = _merge_lines(text)
    text = _clean_and_normalize_headings(text)
    text = _remove_repeating_lines(text)
    text = _remove_headers_footers(text)
    text = _normalize_whitespace(text)
    return text


def stage_clean(force: bool) -> None:
    CLEANED_DIR.mkdir(exist_ok=True)
    mds = sorted(PARSED_DIR.glob("*.md"))
    if not mds:
        print("[WARN] No markdown files in parsed_markdowns/ — run parse stage first")
        return
    for path in mds:
        out = CLEANED_DIR / path.name
        if out.exists() and not force:
            print(f"[SKIP] {path.name} — already cleaned")
            continue
        text = path.read_text(encoding="utf-8")
        cleaned = _clean_text(text)
        out.write_text(cleaned, encoding="utf-8")
        print(f"[OK]   {path.name} → cleaned")

    # Pass through manually-parsed files that may not have a parsed_markdowns/ source
    for path in sorted(CLEANED_DIR.glob("*.md")):
        pass  # already in CLEANED_DIR, no action needed


def _serialize_chunk(chunk, index: int) -> dict:
    return {
        "chunk_index": index,
        "text": chunk.text,
        "token_count": getattr(chunk, "token_count", None),
    }


# ---------------------------------------------------------------------------
# Stage 3a: Neural Chunking
# ---------------------------------------------------------------------------

def stage_chunk_neural(force: bool) -> None:
    from chonkie import NeuralChunker

    NEURAL_DIR.mkdir(exist_ok=True)
    mds = sorted(CLEANED_DIR.glob("*.md"))
    if not mds:
        print("[WARN] No cleaned markdown files — run clean stage first")
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


# ---------------------------------------------------------------------------
# Stage 3b: Semantic Chunking
# ---------------------------------------------------------------------------

def stage_chunk_semantic(force: bool) -> None:
    from chonkie import OverlapRefinery, Pipeline
    from chonkie.types import RecursiveLevel, RecursiveRules

    SEMANTIC_DIR.mkdir(exist_ok=True)
    mds = sorted(CLEANED_DIR.glob("*.md"))
    if not mds:
        print("[WARN] No cleaned markdown files — run clean stage first")
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


# ---------------------------------------------------------------------------
# Stage 4: Enrich Chunks
# ---------------------------------------------------------------------------

_HEADING_EXTRACT_RE = re.compile(r"^#{1,6}\s+(.+)", re.MULTILINE)
_CITATION_RE = re.compile(r"\s*[\[\(][\d,\s.\-]+[\]\)]\s*$")


def _extract_section(text: str, max_offset: int = 120) -> str | None:
    m = _HEADING_EXTRACT_RE.search(text)
    if not m or m.start() > max_offset:
        return None
    heading = _CITATION_RE.sub("", m.group(1)).strip()
    if not heading or len(heading) < 3 or (len(heading.split()) == 1 and len(heading) < 5):
        return None
    return heading


def _extract_page_start(chunk: dict) -> int | None:
    for key in ("page_start", "page", "page_number"):
        val = chunk.get(key)
        if isinstance(val, int):
            return val
        if isinstance(val, str) and val.isdigit():
            return int(val)
    return None


def _load_registry() -> dict[str, dict]:
    result: dict[str, dict] = {}
    with open(REGISTRY_PATH, newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            tier = row["credibility_tier"].strip()
            result[row["title"].strip()] = {
                "doc_id": row["doc_id"].strip(),
                "doc_type": row["doc_type"].strip(),
                "source_org": row["source_org"].strip(),
                "credibility_tier": int(tier) if tier.isdigit() else None,
            }
    return result


def stage_enrich(chunker: str, force: bool) -> None:
    ENRICHED_DIR.mkdir(exist_ok=True)
    registry = _load_registry()

    source_dir = NEURAL_DIR if chunker == "neural" else SEMANTIC_DIR
    files = sorted(source_dir.glob("*.json"))
    if not files:
        print(f"[WARN] No JSON files in {source_dir.name}/ — run chunk stage first")
        return

    total_docs = total_chunks = 0

    for path in files:
        stem = path.stem
        out = ENRICHED_DIR / f"{registry[stem]['doc_id']}.json" if stem in registry else None

        if stem not in registry:
            print(f"[SKIP] {path.name} — not in registry.csv")
            continue

        if out and out.exists() and not force:
            print(f"[SKIP] {path.name} — enriched output already exists")
            continue

        meta = registry[stem]
        doc_id = meta["doc_id"]
        data = json.loads(path.read_text(encoding="utf-8"))

        current_section: str | None = None
        enriched: list[dict] = []

        for chunk in data.get("chunks", []):
            found = _extract_section(chunk["text"])
            if found:
                current_section = found

            enriched.append(
                {
                    "chunk_id": f"{doc_id}_c{chunk['chunk_index']:03d}",
                    "doc_id": doc_id,
                    "text": chunk["text"],
                    "token_count": chunk.get("token_count"),
                    "section": current_section,
                    "page_start": _extract_page_start(chunk),
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
        out.write_text(json.dumps(output, ensure_ascii=False, indent=2), encoding="utf-8")

        total_docs += 1
        total_chunks += len(enriched)
        print(f"[OK]   {stem} → {out.name} ({len(enriched)} chunks)")

    print(f"\nEnriched: {total_docs} docs, {total_chunks} chunks total → {ENRICHED_DIR.name}/")


# ---------------------------------------------------------------------------
# Stage 5: Build Vector Index
# ---------------------------------------------------------------------------

def stage_index(force: bool) -> None:
    import numpy as np
    import sqlite3
    import sqlite_vec
    from sentence_transformers import SentenceTransformer

    if DB_PATH.exists() and not force:
        print(f"[SKIP] {DB_PATH.name} already exists (use --force to rebuild)")
        return

    files = sorted(ENRICHED_DIR.glob("*.json"))
    if not files:
        print("[WARN] No enriched chunks found — run enrich stage first")
        return

    all_chunks: list[dict] = []
    for p in files:
        data = json.loads(p.read_text(encoding="utf-8"))
        all_chunks.extend(data["chunks"])

    print(f"Loaded {len(all_chunks)} enriched chunks")

    if DB_PATH.exists():
        DB_PATH.unlink()

    conn = sqlite3.connect(DB_PATH)
    conn.enable_load_extension(True)
    sqlite_vec.load(conn)
    conn.enable_load_extension(False)

    conn.execute("""
        CREATE TABLE chunks (
            rowid            INTEGER PRIMARY KEY AUTOINCREMENT,
            chunk_id         TEXT    UNIQUE NOT NULL,
            doc_id           TEXT    NOT NULL,
            text             TEXT    NOT NULL,
            token_count      INTEGER,
            section          TEXT,
            page_start       INTEGER,
            doc_type         TEXT,
            source_org       TEXT,
            credibility_tier INTEGER
        )
    """)
    conn.execute(f"CREATE VIRTUAL TABLE vec_chunks USING vec0(embedding float[{EMBED_DIM}])")
    conn.execute("""
        CREATE VIRTUAL TABLE chunks_fts USING fts5(
            text,
            content='chunks',
            content_rowid='rowid',
            tokenize='porter ascii'
        )
    """)

    print(f"Embedding with '{EMBED_MODEL}'...")
    model = SentenceTransformer(EMBED_MODEL)
    texts = [c["text"] for c in all_chunks]
    embeddings: np.ndarray = model.encode(
        texts, batch_size=BATCH_SIZE, show_progress_bar=True, normalize_embeddings=True
    )

    conn.execute("BEGIN")
    for chunk, vec in zip(all_chunks, embeddings):
        conn.execute(
            "INSERT INTO chunks (chunk_id, doc_id, text, token_count, section, page_start, doc_type, source_org, credibility_tier) VALUES (?,?,?,?,?,?,?,?,?)",
            (
                chunk["chunk_id"], chunk["doc_id"], chunk["text"],
                chunk.get("token_count"), chunk.get("section"), chunk.get("page_start"),
                chunk.get("doc_type"), chunk.get("source_org"), chunk.get("credibility_tier"),
            ),
        )
        rowid = conn.execute("SELECT last_insert_rowid()").fetchone()[0]
        arr = vec.astype(np.float32)
        vec_bytes = struct.pack(f"{len(arr)}f", *arr)
        conn.execute("INSERT INTO vec_chunks(rowid, embedding) VALUES (?, ?)", (rowid, vec_bytes))
    conn.execute("COMMIT")

    conn.execute("INSERT INTO chunks_fts(chunks_fts) VALUES('rebuild')")
    conn.commit()

    # Smoke test
    sample = embeddings[0].astype(np.float32)
    sample_bytes = struct.pack(f"{len(sample)}f", *sample)
    rows = conn.execute(
        "SELECT c.chunk_id, v.distance FROM vec_chunks v JOIN chunks c ON v.rowid = c.rowid WHERE v.embedding MATCH ? AND k = 3 ORDER BY v.distance",
        [sample_bytes],
    ).fetchall()
    conn.close()

    size_mb = DB_PATH.stat().st_size / 1_000_000
    print(f"Smoke-test KNN (k=3): {[r[0] for r in rows]}")
    print(f"Done. {len(all_chunks)} chunks → {DB_PATH.name} ({size_mb:.1f} MB)")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

ALL_STAGES = ["parse", "clean", "chunk", "enrich", "index"]


def main() -> None:
    parser = argparse.ArgumentParser(description="Run the full RAG ingestion pipeline.")
    parser.add_argument(
        "--stages",
        nargs="+",
        choices=ALL_STAGES,
        default=ALL_STAGES,
        metavar="STAGE",
        help=f"Stages to run (default: all). Choices: {ALL_STAGES}",
    )
    parser.add_argument(
        "--chunker",
        choices=["neural", "semantic", "both"],
        default="neural",
        help="Chunking strategy to use (default: neural)",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Rebuild outputs even if they already exist",
    )
    args = parser.parse_args()

    stages = args.stages
    chunker = args.chunker
    force = args.force

    print(f"Pipeline: stages={stages}  chunker={chunker}  force={force}\n")

    if "parse" in stages:
        print("=== Stage 1: Parse PDFs ===")
        stage_parse(force)
        print()

    if "clean" in stages:
        print("=== Stage 2: Clean Markdown ===")
        stage_clean(force)
        print()

    if "chunk" in stages:
        if chunker in ("neural", "both"):
            print("=== Stage 3a: Neural Chunking ===")
            stage_chunk_neural(force)
            print()
        if chunker in ("semantic", "both"):
            print("=== Stage 3b: Semantic Chunking ===")
            stage_chunk_semantic(force)
            print()

    if "enrich" in stages:
        # When --chunker both, enrich from neural (the primary pipeline)
        enrich_from = "neural" if chunker in ("neural", "both") else "semantic"
        print(f"=== Stage 4: Enrich Chunks (from {enrich_from}_chunks/) ===")
        stage_enrich(enrich_from, force)
        print()

    if "index" in stages:
        print("=== Stage 5: Build Vector Index ===")
        stage_index(force)
        print()

    print("Pipeline complete.")


if __name__ == "__main__":
    main()
