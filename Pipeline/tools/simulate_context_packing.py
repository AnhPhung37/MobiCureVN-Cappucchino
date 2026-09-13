#!/usr/bin/env python3
"""Reproduce what actually reaches the model after prompt packing.

Retrieval quality is not grounding quality. `MedicalChatOrchestrator.applyContextBudget`
packs the retrieved chunks into `contextTokenBudget` before the model sees anything, and
the original implementation discarded most of them (see Docs/BE/Context-Budget-Finding.md).
This script mirrors both packing policies in Python so the effect can be measured on the
golden set without a device:

  old  -- `break` on the first chunk that does not fit (the shipped bug)
  new  -- pack every chunk that fits whole, then spend the remainder on the head of the
          highest-ranked chunk that did not fit, guarded by a minimum useful size
          (final/context-budget-fix)

It reports, per configuration: chunks actually sent, estimated context tokens, the share of
queries that reach the model with ZERO context, and doc-hit@k over what the model actually
sees rather than what retrieval returned.

RUN ON THE MAC STUDIO, NOT A LAPTOP. It embeds all 209 golden queries per top-k value.

    python -m tools.simulate_context_packing                         # the reference grid
    python -m tools.simulate_context_packing --policy new --top-k 10 --budget 3000
    python -m tools.simulate_context_packing --out ../Docs/test-runs/packing.json

Reference numbers (1238-chunk index, hybrid retriever, CPU, 2026-09-13):
    old, k=5,  budget 600,  ratio 1.4  -> 1.52 sent, 22.5% zero-context, doc-hit seen 0.4450
    new, k=5,  budget 2000, ratio 1.75 -> 4.51 sent,  0.0% zero-context, doc-hit seen 0.7416
    new, k=10, budget 2000, ratio 1.75 -> 6.20 sent,  0.0% zero-context, doc-hit seen 0.7512
    new, k=10, budget 3000, ratio 1.75 -> 7.50 sent,  0.0% zero-context, doc-hit seen 0.8134

1.75 is Qwen 3.5's measured ratio (ModelCatalog.wordsToTokensRatio); pass each model's own.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sqlite3
import sys
from pathlib import Path

_ROOT = Path(__file__).resolve().parent.parent


def _pin_device(device: str) -> None:
    # Must run before torch is imported anywhere. An unpinned run lets PyTorch take a CUDA
    # card and OOM on it -- the failure that ended the first attempt at this measurement.
    if device == "cpu":
        os.environ["CUDA_VISIBLE_DEVICES"] = ""


# Mirrors MedicalChatOrchestrator.minimumUsefulChunkTokens.
MIN_USEFUL_CHUNK_TOKENS = 80


def estimate_tokens(text: str, ratio: float) -> int:
    """Mirrors MedicalChatOrchestrator.estimateTokens: whitespace words x ratio, rounded up."""
    return math.ceil(len(text.split()) * ratio)


def pack_old(
    chunks: list[str], text: dict[str, str], budget: int, ratio: float
) -> tuple[list[str], int]:
    used, out = 0, []
    for cid in chunks:
        cost = estimate_tokens(text.get(cid, ""), ratio)
        if used + cost > budget:
            break
        used += cost
        out.append(cid)
    return out, used


def _tokens_for_words(words: int, ratio: float) -> int:
    """Mirrors MedicalChatOrchestrator.tokens(forWords:ratio:)."""
    return math.ceil(words * ratio)


def _head_words(body: str, remaining: int, ratio: float) -> int | None:
    """Mirrors MedicalChatOrchestrator.head(of:fittingTokens:ratio:): the most words of `body`
    that, plus the one-word truncation marker, cost at most `remaining`."""
    allowed = int(remaining / ratio) - 1
    while allowed >= 1 and _tokens_for_words(allowed + 1, ratio) > remaining:
        allowed -= 1
    if allowed < 1 or len(body.split()) <= allowed:
        return None
    return allowed


def pack_new(
    chunks: list[str], text: dict[str, str], budget: int, ratio: float
) -> tuple[list[str], int]:
    """Mirrors the Swift applyContextBudget on final/context-budget-fix: every chunk that fits
    whole, in rank order; then the remainder spent on the head of the highest-ranked chunk that
    did not fit, kept at its rank."""
    if budget <= 0:
        return [], 0
    used, fits, first_skipped = 0, set(), None
    for cid in chunks:
        cost = estimate_tokens(text.get(cid, ""), ratio)
        if used + cost <= budget:
            used += cost
            fits.add(cid)
        elif first_skipped is None:
            first_skipped = cid
    remaining = budget - used
    if first_skipped is not None and remaining >= MIN_USEFUL_CHUNK_TOKENS:
        allowed = _head_words(text.get(first_skipped, ""), remaining, ratio)
        if allowed is not None:
            used += _tokens_for_words(allowed + 1, ratio)
            fits.add(first_skipped)
    return [cid for cid in chunks if cid in fits], used


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--index",
        type=Path,
        default=_ROOT / "eval" / "outputs" / "vectorstore_neural.db",
    )
    parser.add_argument("--policy", choices=["old", "new", "both"], default="both")
    parser.add_argument("--top-k", type=int, nargs="+", default=[5, 10])
    parser.add_argument("--budget", type=int, nargs="+", default=[600, 2000, 3000])
    parser.add_argument("--ratio", type=float, nargs="+", default=[1.4, 1.6])
    parser.add_argument("--device", default="cpu", help="cpu (default) / mps / cuda")
    parser.add_argument("--out", type=Path, default=None)
    args = parser.parse_args()

    _pin_device(args.device)
    sys.path.insert(0, str(_ROOT))
    from eval.dataset import load_qrels, load_queries
    from eval.metrics_ir import doc_hit_at_k
    from eval.retriever import Embedder, HybridRetriever

    if not args.index.exists():
        raise SystemExit(
            f"{args.index} not found -- run `python -m eval.build_indexes` first."
        )

    queries = load_queries(_ROOT / "eval" / "data" / "queries.jsonl")
    qrels = load_qrels(_ROOT / "eval" / "data" / "qrels.jsonl")

    embedder = Embedder("BAAI/bge-small-en-v1.5")
    embedder._model.to(args.device)
    # Match what the app ships (SQLiteRetriever.swift always fuses and drops stopwords).
    retriever = HybridRetriever(
        args.index, embedder, always_fuse=True, drop_stopwords=True
    )

    conn = sqlite3.connect(f"file:{args.index}?mode=ro", uri=True)
    text = dict(conn.execute("SELECT chunk_id, text FROM chunks"))
    conn.close()

    retrieved: dict[int, dict[str, list[str]]] = {}
    for k in sorted(set(args.top_k)):
        retrieved[k] = {
            q.query_id: [c.chunk_id for c in retriever.search(q.question, k)]
            for q in queries
        }

    policies = ["old", "new"] if args.policy == "both" else [args.policy]
    packers = {"old": pack_old, "new": pack_new}

    rows = []
    print(
        f"{'policy':<7}{'k':>4}{'budget':>8}{'ratio':>7}{'sent':>7}{'ctx tok':>9}{'zero-ctx':>10}{'doc-hit seen':>14}"
    )
    print("-" * 66)
    for policy in policies:
        for k in sorted(set(args.top_k)):
            for budget in args.budget:
                for ratio in args.ratio:
                    sent = tokens = zero = hits = 0
                    for q in queries:
                        gold = set(qrels[q.query_id].relevant_chunk_ids)
                        selected, used = packers[policy](
                            retrieved[k][q.query_id], text, budget, ratio
                        )
                        sent += len(selected)
                        tokens += used
                        zero += not selected
                        hits += doc_hit_at_k(gold, selected, k)
                    n = len(queries)
                    row = {
                        "policy": policy,
                        "top_k": k,
                        "budget": budget,
                        "ratio": ratio,
                        "chunks_sent": sent / n,
                        "context_tokens": tokens / n,
                        "zero_context_rate": zero / n,
                        "doc_hit_seen": hits / n,
                    }
                    rows.append(row)
                    print(
                        f"{policy:<7}{k:>4}{budget:>8}{ratio:>7.2f}{row['chunks_sent']:>7.2f}"
                        f"{row['context_tokens']:>9.0f}{row['zero_context_rate']:>9.1%}{row['doc_hit_seen']:>14.4f}"
                    )

    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(
            json.dumps({"index": str(args.index), "rows": rows}, indent=2),
            encoding="utf-8",
        )
        print(f"\nWrote {args.out}")


if __name__ == "__main__":
    main()
