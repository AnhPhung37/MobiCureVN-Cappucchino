"""
smoke_retrieve.py — quick retrieval sanity check against the built vectorstore.db.

Mirrors the app's retrieval: embeds the query with BAAI/bge-small-en-v1.5 and
runs a sqlite-vec KNN, then prints the top hits (doc_id + snippet). Includes
queries that should land on the NEWLY added documents.

Usage:
    .venv/bin/python tools/smoke_retrieve.py
    .venv/bin/python tools/smoke_retrieve.py "your question here"
"""
from __future__ import annotations

import struct
import sys
from pathlib import Path

import sqlite3
import sqlite_vec
from sentence_transformers import SentenceTransformer

DB_PATH = Path(__file__).parent.parent / "data" / "vectorstore.db"
EMBED_MODEL = "BAAI/bge-small-en-v1.5"
TOP_K = 5

# Questions chosen to probe the newly-added docs (2026 NCCN, DPYD, ostomy, NHS surgery).
DEFAULT_QUERIES = [
    "What are the treatment options for stage III rectal cancer?",
    "What is DPYD testing and why does it matter before chemotherapy?",
    "How do I care for my stoma after a colostomy?",
    "What should I expect going home after a right hemicolectomy?",
    "What are the most common signs and symptoms of colorectal cancer?",
]


def embed(model: SentenceTransformer, text: str) -> bytes:
    vec = model.encode([text], normalize_embeddings=True)[0]
    return struct.pack(f"{len(vec)}f", *vec.astype("float32"))


def main() -> None:
    queries = [sys.argv[1]] if len(sys.argv) > 1 else DEFAULT_QUERIES

    conn = sqlite3.connect(DB_PATH)
    conn.enable_load_extension(True)
    sqlite_vec.load(conn)
    conn.enable_load_extension(False)

    print(f"Loading {EMBED_MODEL}...")
    model = SentenceTransformer(EMBED_MODEL)

    for q in queries:
        qbytes = embed(model, q)
        rows = conn.execute(
            """
            SELECT c.doc_id, c.chunk_id, v.distance, substr(c.text, 1, 120)
            FROM vec_chunks v JOIN chunks c ON v.rowid = c.rowid
            WHERE v.embedding MATCH ? AND k = ?
            ORDER BY v.distance
            """,
            [qbytes, TOP_K],
        ).fetchall()
        print(f"\nQ: {q}")
        for doc_id, chunk_id, dist, snippet in rows:
            print(f"  [{dist:.3f}] {doc_id:<16} {chunk_id:<20} {snippet.strip()!r}")

    conn.close()


if __name__ == "__main__":
    main()
