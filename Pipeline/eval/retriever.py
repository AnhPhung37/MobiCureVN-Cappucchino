from __future__ import annotations

import sqlite3
import struct
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import sqlite_vec
from sentence_transformers import SentenceTransformer


@dataclass(frozen=True)
class RetrievedChunk:
    chunk_id: str
    text: str
    distance: float


class Embedder:
    def __init__(self, model_name: str, batch_size: int = 64) -> None:
        self._model = SentenceTransformer(model_name)
        self._batch_size = batch_size

    def encode(self, texts: list[str], normalize_embeddings: bool = True) -> np.ndarray:
        return self._model.encode(
            texts,
            batch_size=self._batch_size,
            show_progress_bar=False,
            normalize_embeddings=normalize_embeddings,
        )


def _to_bytes(vec: np.ndarray) -> bytes:
    arr = vec.astype(np.float32)
    return struct.pack(f"{len(arr)}f", *arr)


class SQLiteVecRetriever:
    def __init__(self, db_path: Path, embedder: Embedder) -> None:
        self._db_path = db_path
        self._embedder = embedder

    def search(self, question: str, k: int) -> list[RetrievedChunk]:
        embedding = self._embedder.encode([question], normalize_embeddings=True)[0]
        vec = _to_bytes(embedding)

        conn = sqlite3.connect(self._db_path)
        conn.enable_load_extension(True)
        sqlite_vec.load(conn)
        conn.enable_load_extension(False)

        rows = conn.execute(
            """
            SELECT c.chunk_id, c.text, v.distance
            FROM vec_chunks v
            JOIN chunks c ON v.rowid = c.rowid
            WHERE v.embedding MATCH ?
              AND k = ?
            ORDER BY v.distance
            """,
            [vec, k],
        ).fetchall()
        conn.close()

        return [RetrievedChunk(chunk_id=r[0], text=r[1], distance=r[2]) for r in rows]
