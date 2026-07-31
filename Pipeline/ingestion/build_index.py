"""
build_index.py — Stage 5: Embed chunks and build vectorstore.db

Embeds enriched chunks and stores them in vectorstore.db (sqlite-vec).
The output file ships inside the iOS app bundle as a read-only resource.

Input:  enriched_chunks/{doc_id}.json
Output: vectorstore.db

DB layout
---------
chunks (metadata table)
    rowid            INTEGER  PRIMARY KEY AUTOINCREMENT
    chunk_id         TEXT     UNIQUE  — "ACS_CCFS_c002"
    doc_id           TEXT             — "ACS_CCFS"
    text             TEXT
    token_count      INTEGER
    section          TEXT
    page_start       INTEGER
    doc_type         TEXT
    source_org       TEXT
    credibility_tier INTEGER

vec_chunks (sqlite-vec virtual table)
    rowid            INTEGER  FK → chunks.rowid
    embedding        FLOAT[384]

chunks_fts (FTS5 virtual table)
    text             — porter-stemmed full-text index

iOS query (KNN, k=5):
    SELECT c.*, v.distance
    FROM vec_chunks v
    JOIN chunks c ON v.rowid = c.rowid
    WHERE v.embedding MATCH ?
      AND k = 5
    ORDER BY v.distance;

Usage:
    python build_index.py
    python build_index.py --force
"""
from __future__ import annotations

import argparse
import json
import sqlite3
import struct
from pathlib import Path

import numpy as np
import sqlite_vec
from sentence_transformers import SentenceTransformer

_ROOT = Path(__file__).parent.parent
ENRICHED_DIR = _ROOT / "data" / "enriched_chunks"
DB_PATH = _ROOT / "data" / "vectorstore.db"

EMBED_MODEL = "BAAI/bge-small-en-v1.5"
EMBED_DIM = 384
BATCH_SIZE = 64


def _to_bytes(vec: np.ndarray) -> bytes:
    arr = vec.astype(np.float32)
    return struct.pack(f"{len(arr)}f", *arr)


def build_index(
    enriched_dir: Path,
    db_path: Path,
    embed_model: str,
    embed_dim: int,
    batch_size: int,
) -> int:
    """Embed all chunks in enriched_dir and write them to db_path. Returns chunk count."""
    files = sorted(enriched_dir.glob("*.json"))
    if not files:
        raise ValueError(f"No enriched chunks found in {enriched_dir}/")

    all_chunks: list[dict] = []
    for p in files:
        all_chunks.extend(json.loads(p.read_text(encoding="utf-8"))["chunks"])
    print(f"Loaded {len(all_chunks)} enriched chunks from {enriched_dir.name}/")

    if db_path.exists():
        db_path.unlink()
        print(f"Removed existing {db_path.name}")

    conn = sqlite3.connect(db_path)
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
    conn.execute(f"CREATE VIRTUAL TABLE vec_chunks USING vec0(embedding float[{embed_dim}])")
    conn.execute("""
        CREATE VIRTUAL TABLE chunks_fts USING fts5(
            text,
            content='chunks',
            content_rowid='rowid',
            tokenize='porter ascii'
        )
    """)

    print(f"Embedding with '{embed_model}'...")
    model = SentenceTransformer(embed_model)
    texts = [c["text"] for c in all_chunks]
    embeddings: np.ndarray = model.encode(
        texts, batch_size=batch_size, show_progress_bar=True, normalize_embeddings=True
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
        conn.execute("INSERT INTO vec_chunks(rowid, embedding) VALUES (?, ?)", (rowid, _to_bytes(vec)))
    conn.execute("COMMIT")

    conn.execute("INSERT INTO chunks_fts(chunks_fts) VALUES('rebuild')")
    conn.commit()
    print("FTS5 index built")

    sample_bytes = _to_bytes(embeddings[0])
    rows = conn.execute(
        "SELECT c.chunk_id, v.distance FROM vec_chunks v JOIN chunks c ON v.rowid = c.rowid WHERE v.embedding MATCH ? AND k = 3 ORDER BY v.distance",
        [sample_bytes],
    ).fetchall()
    conn.close()

    size_mb = db_path.stat().st_size / 1_000_000
    print(f"Smoke-test KNN (k=3): {[r[0] for r in rows]}")
    print(f"Done. {len(all_chunks)} chunks → {db_path.name} ({size_mb:.1f} MB)")
    return len(all_chunks)


def main(force: bool) -> None:
    if DB_PATH.exists() and not force:
        print(f"[SKIP] {DB_PATH.name} already exists (use --force to rebuild)")
        return
    if not ENRICHED_DIR.exists() or not any(ENRICHED_DIR.glob("*.json")):
        raise SystemExit(f"[ERROR] Run enrich_chunks.py first — {ENRICHED_DIR}/ is empty or missing.")
    build_index(ENRICHED_DIR, DB_PATH, EMBED_MODEL, EMBED_DIM, BATCH_SIZE)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Stage 5: Embed chunks and build vectorstore.db.")
    parser.add_argument("--force", action="store_true", help="Rebuild even if vectorstore.db exists")
    args = parser.parse_args()
    main(args.force)
