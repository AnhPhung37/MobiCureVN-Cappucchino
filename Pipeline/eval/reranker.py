"""Cross-encoder reranking for the eval harness, mirroring SQLiteRetriever's rerank step.

Hybrid retrieval ranks a chunk from the right document into the top five for 161 of the 209
golden questions, but the exact gold chunk for only 52: the candidates are found and then
ordered badly. A cross-encoder reads the question and each candidate together and scores their
relevance directly. The app (`CrossEncoderReranker.swift`) retrieves `rerankCandidates` rows,
scores them with the same model converted to CoreML, and keeps the best `topK`; this module does
the same so the harness measures what ships.
"""

from __future__ import annotations

from .retriever import RetrievedChunk

DEFAULT_RERANK_MODEL = "cross-encoder/ms-marco-MiniLM-L6-v2"


def order_by_scores(scores: list[float]) -> list[int]:
    """Indices best first; ties keep retrieval order (mirrors CrossEncoderReranker.order(byScores:))."""
    return sorted(range(len(scores)), key=lambda i: (-float(scores[i]), i))


class CrossEncoderReranker:
    def __init__(
        self,
        model_name: str = DEFAULT_RERANK_MODEL,
        max_length: int = 512,
        device: str = "cpu",
        batch_size: int = 32,
    ) -> None:
        from sentence_transformers import CrossEncoder

        self.model_name = model_name
        self.max_length = max_length
        self._batch_size = batch_size
        self._model = CrossEncoder(model_name, max_length=max_length, device=device)

    def scores(self, question: str, passages: list[str]) -> list[float]:
        raw = self._model.predict(
            [(question, passage) for passage in passages],
            batch_size=self._batch_size,
            show_progress_bar=False,
        )
        return [float(s) for s in raw]


class RerankingRetriever:
    """Retrieve `candidates` rows with `base`, then keep the best `k` by cross-encoder score."""

    def __init__(self, base, reranker, candidates: int) -> None:
        if candidates < 1:
            raise ValueError("candidates must be at least 1")
        self._base = base
        self._reranker = reranker
        self._candidates = candidates

    def search(self, question: str, k: int) -> list[RetrievedChunk]:
        rows = self._base.search(question, max(k, self._candidates))
        if len(rows) <= 1:
            return rows[:k]
        order = order_by_scores(self._reranker.scores(question, [row.text for row in rows]))
        return [rows[i] for i in order][:k]
