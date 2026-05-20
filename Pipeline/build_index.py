"""
build_index.py

Embeds enriched chunks and stores them in vectorstore.db (sqlite-vec).
The output file ships inside the iOS app bundle as a read-only resource.

Run from DocumentsChunking/:
    python enrich_chunks.py   # must run first
    python build_index.py

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

iOS query (KNN, k=5):
    SELECT c.*, v.distance
    FROM vec_chunks v
    JOIN chunks c ON v.rowid = c.rowid
    WHERE v.embedding MATCH ?
      AND k = 5
    ORDER BY v.distance;
"""

import json
import sqlite3
import struct
from pathlib import Path

import numpy as np
import sqlite_vec
from sentence_transformers import SentenceTransformer

ENRICHED_DIR = Path("enriched_chunks")
DB_PATH = Path("vectorstore.db")

EMBED_MODEL = "BAAI/bge-small-en-v1.5"
EMBED_DIM = 384
BATCH_SIZE = 64


def load_all_chunks() -> list[dict]:
    chunks: list[dict] = []
    for path in sorted(ENRICHED_DIR.glob("*.json")):
        with open(path, encoding="utf-8") as f:
            chunks.extend(json.load(f)["chunks"])
    return chunks


def _to_bytes(vec: np.ndarray) -> bytes:
    arr = vec.astype(np.float32)
    return struct.pack(f"{len(arr)}f", *arr)


def build(chunks: list[dict], model: SentenceTransformer) -> None:
    if DB_PATH.exists():
        DB_PATH.unlink()
        print(f"Removed existing {DB_PATH}")

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

    conn.execute(f"""
        CREATE VIRTUAL TABLE vec_chunks USING vec0(
            embedding float[{EMBED_DIM}]
        )
    """)

    conn.execute("""
        CREATE VIRTUAL TABLE chunks_fts USING fts5(
            text,
            content='chunks',
            content_rowid='rowid',
            tokenize='porter ascii'
        )
    """)

    texts = [c["text"] for c in chunks]
    print(f"Embedding {len(texts)} chunks with '{EMBED_MODEL}'...")

    embeddings: np.ndarray = model.encode(
        texts,
        batch_size=BATCH_SIZE,
        show_progress_bar=True,
        normalize_embeddings=True,
    )

    conn.execute("BEGIN")
    for chunk, vec in zip(chunks, embeddings):
        conn.execute(
            """
            INSERT INTO chunks
                (chunk_id, doc_id, text, token_count, section, page_start, doc_type, source_org, credibility_tier)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                chunk["chunk_id"],
                chunk["doc_id"],
                chunk["text"],
                chunk.get("token_count"),
                chunk.get("section"),
                chunk.get("page_start"),
                chunk.get("doc_type"),
                chunk.get("source_org"),
                chunk.get("credibility_tier"),
            ),
        )
        rowid = conn.execute("SELECT last_insert_rowid()").fetchone()[0]
        conn.execute(
            "INSERT INTO vec_chunks(rowid, embedding) VALUES (?, ?)",
            (rowid, _to_bytes(vec)),
        )
    conn.execute("COMMIT")

    conn.execute("INSERT INTO chunks_fts(chunks_fts) VALUES('rebuild')")
    conn.commit()
    print(f"FTS5 index built")

    # Smoke-test: verify KNN works
    sample_vec = _to_bytes(embeddings[0])
    rows = conn.execute(
        "SELECT c.chunk_id, v.distance FROM vec_chunks v JOIN chunks c ON v.rowid = c.rowid WHERE v.embedding MATCH ? AND k = 3 ORDER BY v.distance",
        [sample_vec],
    ).fetchall()
    print(f"\nSmoke-test KNN (k=3): {[r[0] for r in rows]}")

    conn.close()

    size_mb = DB_PATH.stat().st_size / 1_000_000
    print(f"Done. {len(chunks)} chunks → {DB_PATH}  ({size_mb:.1f} MB)")


if __name__ == "__main__":
    if not ENRICHED_DIR.exists() or not any(ENRICHED_DIR.glob("*.json")):
        raise SystemExit(
            f"[ERROR] Run enrich_chunks.py first — {ENRICHED_DIR}/ is empty or missing."
        )

    all_chunks = load_all_chunks()
    print(f"Loaded {len(all_chunks)} enriched chunks from {ENRICHED_DIR}/")

    embedder = SentenceTransformer(EMBED_MODEL)
    build(all_chunks, embedder)
