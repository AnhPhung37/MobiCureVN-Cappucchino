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


class HybridRetriever:
    """Faithful port of the app's SQLiteRetriever (App/Backend/Services/RAG/SQLiteRetriever.swift).

    Hybrid retrieval, mirroring production so eval scores reflect what ships:
      1. FTS5 keyword search (BM25), OR-joined prefix tokens — always run.
      2. sqlite-vec KNN — run only when FTS returns fewer than candidate_limit rows
         (the app skips the expensive embedding pass when FTS is already full).
      3. Fuse with Reciprocal Rank Fusion (k=rrf_k), then dedupe by content fingerprint.

    Query enrichment (enrichedTerms) is not modelled — the eval has no enrichment stage.
    """

    # Common English stopwords >= 3 chars that survive the length filter and dilute BM25.
    _STOPWORDS = {
        "the", "and", "are", "for", "can", "you", "how", "does", "did", "with", "what",
        "your", "why", "who", "was", "were", "has", "have", "had", "will", "would",
        "should", "could", "that", "this", "these", "those", "there", "their", "them",
        "then", "than", "from", "into", "out", "off", "not", "but", "any", "all", "some",
        "get", "got", "may", "might", "must", "about", "when", "which", "where", "whom",
    }

    def __init__(
        self,
        db_path: Path,
        embedder: Embedder,
        candidate_multiplier: int = 3,
        rrf_k: float = 60.0,
        min_token_length: int = 3,
        always_fuse: bool = False,
        drop_stopwords: bool = False,
    ) -> None:
        self._db_path = db_path
        self._embedder = embedder
        self._candidate_multiplier = candidate_multiplier
        self._rrf_k = rrf_k
        self._min_token_length = min_token_length
        # always_fuse: run the vector pass and RRF-fuse even when FTS is full (app skips it).
        self._always_fuse = always_fuse
        # drop_stopwords: remove common stopwords from the FTS query to sharpen BM25.
        self._drop_stopwords = drop_stopwords
        self._conn = sqlite3.connect(db_path)
        self._conn.enable_load_extension(True)
        sqlite_vec.load(self._conn)
        self._conn.enable_load_extension(False)
        self._has_fts = self._table_exists("chunks_fts")
        self._has_vec = self._table_exists("vec_chunks")

    def _table_exists(self, name: str) -> bool:
        row = self._conn.execute(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name=? LIMIT 1", [name]
        ).fetchone()
        return row is not None

    def _tokenize(self, text: str) -> list[str]:
        # Mirror tokenizeForFTS: strip non-alphanumerics, keep tokens >= min length,
        # dedupe, append a prefix wildcard.
        seen: dict[str, None] = {}
        for raw in text.split():
            cleaned = "".join(ch for ch in raw if ch.isalnum())
            if len(cleaned) < self._min_token_length:
                continue
            if self._drop_stopwords and cleaned.lower() in self._STOPWORDS:
                continue
            token = f"{cleaned}*"
            seen.setdefault(token, None)
        return list(seen.keys())

    def _run_fts(self, question: str, limit: int) -> list[tuple[str, str]]:
        if not self._has_fts:
            return []
        tokens = self._tokenize(question)
        if not tokens:
            return []
        match = " OR ".join(tokens)  # OR, not AND — avoids over-constraining (see Swift note)
        rows = self._conn.execute(
            """
            SELECT c.chunk_id, c.text
            FROM chunks_fts fts
            JOIN chunks c ON fts.rowid = c.rowid
            WHERE chunks_fts MATCH ?
            ORDER BY rank
            LIMIT ?
            """,
            [match, limit],
        ).fetchall()
        return [(r[0], r[1]) for r in rows]

    def _run_vector(self, question: str, limit: int) -> list[tuple[str, str]]:
        if not self._has_vec:
            return []
        embedding = self._embedder.encode([question], normalize_embeddings=True)[0]
        vec = _to_bytes(embedding)
        rows = self._conn.execute(
            """
            SELECT c.chunk_id, c.text
            FROM vec_chunks v
            JOIN chunks c ON v.rowid = c.rowid
            WHERE v.embedding MATCH ? AND k = ?
            ORDER BY v.distance
            """,
            [vec, limit],
        ).fetchall()
        return [(r[0], r[1]) for r in rows]

    def _merge_rrf(
        self, fts: list[tuple[str, str]], vector: list[tuple[str, str]]
    ) -> list[tuple[str, str]]:
        if not vector:
            return fts
        if not fts:
            return vector
        fts_rank = {cid: i + 1 for i, (cid, _) in enumerate(fts)}
        vec_rank = {cid: i + 1 for i, (cid, _) in enumerate(vector)}
        text_by_id: dict[str, str] = {}
        for cid, text in fts:
            text_by_id[cid] = text
        for cid, text in vector:
            text_by_id[cid] = text
        scored = []
        for cid, text in text_by_id.items():
            score = 0.0
            if cid in fts_rank:
                score += 1.0 / (self._rrf_k + fts_rank[cid])
            if cid in vec_rank:
                score += 1.0 / (self._rrf_k + vec_rank[cid])
            scored.append((score, cid, text))
        scored.sort(key=lambda t: t[0], reverse=True)
        return [(cid, text) for _, cid, text in scored]

    @staticmethod
    def _dedupe_by_content(rows: list[tuple[str, str]]) -> list[tuple[str, str]]:
        import re

        seen: set[str] = set()
        out: list[tuple[str, str]] = []
        for cid, text in rows:
            normalized = re.sub(r"\s+", " ", text.lower()).strip()
            fingerprint = normalized[:200]
            if fingerprint not in seen:
                seen.add(fingerprint)
                out.append((cid, text))
        return out

    def search(self, question: str, k: int) -> list[RetrievedChunk]:
        candidate_limit = max(k * self._candidate_multiplier, k)
        fts_rows = self._run_fts(question, candidate_limit)
        # App behaviour: skip the vector pass when FTS already returned a full candidate set.
        # always_fuse overrides that and runs vector every time.
        skip_vector = (not self._always_fuse) and len(fts_rows) >= candidate_limit
        vector_rows = [] if skip_vector else self._run_vector(question, candidate_limit)
        merged = self._merge_rrf(fts_rows, vector_rows)
        deduped = self._dedupe_by_content(merged)
        final = deduped[:k]
        # distance is not meaningful post-fusion; expose rank-derived score for parity of shape.
        return [
            RetrievedChunk(chunk_id=cid, text=text, distance=float(rank))
            for rank, (cid, text) in enumerate(final, start=1)
        ]
