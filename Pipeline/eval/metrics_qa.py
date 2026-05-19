from __future__ import annotations

import re
from typing import Iterable

import numpy as np


_SENTENCE_RE = re.compile(r"[^.!?]+[.!?]?")


def _split_sentences(text: str) -> list[str]:
    sentences = [s.strip() for s in _SENTENCE_RE.findall(text) if s.strip()]
    return sentences


def answer_similarity(answer: str, reference: str, embedder) -> float:
    vectors = embedder.encode([answer, reference], normalize_embeddings=True)
    return float(vectors[0] @ vectors[1])


def faithfulness(answer: str, context: str, embedder) -> float:
    sentences = _split_sentences(answer)
    if not sentences:
        return 0.0

    context_vec = embedder.encode([context], normalize_embeddings=True)[0]
    sent_vecs = embedder.encode(sentences, normalize_embeddings=True)
    scores = sent_vecs @ context_vec
    scores = np.clip(scores, 0.0, 1.0)
    return float(np.mean(scores))


def safe_mean(values: Iterable[float]) -> float:
    values = list(values)
    if not values:
        return 0.0
    return float(sum(values) / len(values))
