#!/usr/bin/env python3
"""Reproduce what actually reaches the model after prompt packing.

Retrieval quality is not grounding quality. `MedicalChatOrchestrator.applyContextBudget`
packs the retrieved chunks into `contextTokenBudget` before the model sees anything, and
the original implementation discarded most of them (see Docs/BE/Context-Budget-Finding.md).
This script mirrors both packing policies in Python so the effect can be measured on the
golden set without a device:

  old  -- `break` on the first chunk that does not fit (the shipped bug)
  new  -- `continue` past it, then spend the remainder on the head of the next chunk,
          guarded by a minimum useful size (final/context-budget-fix)

It reports, per configuration: chunks actually sent, estimated context tokens, the share of
queries that reach the model with ZERO context, and doc-hit@k over what the model actually
sees rather than what retrieval returned.

RUN ON THE MAC STUDIO, NOT A LAPTOP. It embeds all 209 golden queries per top-k value.

    python -m tools.simulate_context_packing                         # the reference grid
    python -m tools.simulate_context_packing --policy new --top-k 10 --budget 3000
    python -m tools.simulate_context_packing --out ../Docs/test-runs/packing.json

Reference numbers (1238-chunk index, CPU, 2026-09-12):
    old, k=5,  budget 600,  ratio 1.4 -> 1.52 sent, 22.5% zero-context, doc-hit seen 0.4450
    new, k=5,  budget 2000, ratio 1.6 -> 3.96 sent,  0.0% zero-context, doc-hit seen 0.6890
    new, k=10, budget 3000, ratio 1.6 -> 6.40 sent,  0.0% zero-context, doc-hit seen 0.7512
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


def pack_new(
    chunks: list[str], text: dict[str, str], budget: int, ratio: float
) -> tuple[list[str], int]:
    """Mirrors the Swift applyContextBudget on final/context-budget-fix."""
    if budget <= 0:
        return [], 0
    used, out = 0, []
    for cid in chunks:
        body = text.get(cid, "")
        cost = estimate_tokens(body, ratio)
        if used + cost <= budget:
            used += cost
            out.append(cid)
            continue
        remaining = budget - used
        if remaining < MIN_USEFUL_CHUNK_TOKENS:
            continue
        allowed_words = int(remaining / ratio)
        words = body.split()
        if allowed_words <= 0 or len(words) <= allowed_words:
            continue
        used += estimate_tokens(" ".join(words[:allowed_words]), ratio)
        out.append(cid)
        break
    return out, used


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
                        f"{policy:<7}{k:>4}{budget:>8}{ratio:>7.1f}{row['chunks_sent']:>7.2f}"
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
