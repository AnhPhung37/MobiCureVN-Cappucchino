from __future__ import annotations

import json
import sqlite3
import struct
from pathlib import Path

import numpy as np
import sqlite_vec
from sentence_transformers import SentenceTransformer


def _to_bytes(vec: np.ndarray) -> bytes:
    arr = vec.astype(np.float32)
    return struct.pack(f"{len(arr)}f", *arr)


def load_all_chunks(enriched_dir: Path) -> list[dict]:
    chunks: list[dict] = []
    for path in sorted(enriched_dir.glob("*.json")):
        with open(path, encoding="utf-8") as f:
            chunks.extend(json.load(f)["chunks"])
    return chunks


def build_index(
    enriched_dir: Path,
    db_path: Path,
    embed_model: str,
    embed_dim: int,
    batch_size: int,
) -> int:
    if db_path.exists():
        db_path.unlink()
        print(f"Removed existing {db_path}")

    chunks = load_all_chunks(enriched_dir)
    if not chunks:
        raise ValueError(f"No chunks found in {enriched_dir}")

    model = SentenceTransformer(embed_model)
    texts = [c["text"] for c in chunks]

    embeddings: np.ndarray = model.encode(
        texts,
        batch_size=batch_size,
        show_progress_bar=True,
        normalize_embeddings=True,
    )

    conn = sqlite3.connect(db_path)
    conn.enable_load_extension(True)
    sqlite_vec.load(conn)
    conn.enable_load_extension(False)

    conn.execute(
        """
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
        """
    )

    conn.execute(
        f"""
        CREATE VIRTUAL TABLE vec_chunks USING vec0(
            embedding float[{embed_dim}]
        )
        """
    )

    # Mirror the shipped index (ingestion/build_index.py): the app's retriever is
    # hybrid FTS5 + vector, so the eval index must carry the same FTS5 table or the
    # hybrid path silently degrades to vector-only.
    conn.execute(
        """
        CREATE VIRTUAL TABLE chunks_fts USING fts5(
            text,
            content='chunks',
            content_rowid='rowid',
            tokenize='porter ascii'
        )
        """
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
    conn.close()

    return len(chunks)
