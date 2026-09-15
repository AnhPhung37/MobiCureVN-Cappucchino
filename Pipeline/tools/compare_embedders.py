#!/usr/bin/env python3
"""Compare candidate retrieval embedders, including cross-lingual behaviour.

Question this answers: can a Vietnamese query retrieve from the English corpus
*directly*, or is the VI→EN translation round-trip in the app mandatory?

RUN THIS ON THE MAC STUDIO, NOT A LAPTOP. It loads several transformer models and
embeds the whole corpus with each. `--device cpu` is the default and is deliberate:
an unpinned run lets PyTorch grab CUDA and OOM on a small card.

    python -m tools.compare_embedders                      # the three defaults
    python -m tools.compare_embedders --models BAAI/bge-m3
    python -m tools.compare_embedders --device mps         # Apple Silicon
    python -m tools.compare_embedders --out ../Docs/audits/embedder-comparison.json

Prerequisites: eval/outputs/enriched_neural must exist (`python -m eval.build_indexes`),
and the golden set + eval/data/queries_vi.jsonl must be present.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

import numpy as np

_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_ROOT))

from eval.dataset import load_qrels, load_queries  # noqa: E402
from eval.index_builder import load_all_chunks  # noqa: E402
from eval.metrics_ir import doc_hit_at_k, doc_id_of, mrr, ndcg_at_k, recall_at_k  # noqa: E402


# Each family has its own required input convention. Getting this wrong is not a
# detail: the e5 family is TRAINED with "query: " / "passage: " prefixes and loses
# real accuracy without them — the first run of this comparison omitted them and
# under-reported e5 as a result. bge-m3 takes no prefix. bge-v1.5 takes an optional
# retrieval instruction on the QUERY side only.
MODEL_PREFIXES: dict[str, tuple[str, str]] = {
    "intfloat/multilingual-e5-small": ("query: ", "passage: "),
    "intfloat/multilingual-e5-base": ("query: ", "passage: "),
    "intfloat/multilingual-e5-large": ("query: ", "passage: "),
    "BAAI/bge-m3": ("", ""),
    "BAAI/bge-small-en-v1.5": ("", ""),
    # Candidates from Docs/BE/Embedder-Candidates.md. Both ship their prompts in
    # config_sentence_transformers.json; they are spelled out here so a run records exactly
    # what was prepended, as for e5 above.
    "Qwen/Qwen3-Embedding-0.6B": (
        "Instruct: Given a web search query, retrieve relevant passages that answer the query\nQuery:",
        "",
    ),
    "google/embeddinggemma-300m": ("task: search result | query: ", "title: none | text: "),
}

# The instruction bge-v1.5 documents for retrieval. NOT currently used by the shipped
# pipeline (ingestion/build_index.py and eval/retriever.py both encode plain), which
# is at least self-consistent. Worth one run with --bge-instruction to see whether it
# is leaving anything on the table.
BGE_QUERY_INSTRUCTION = "Represent this sentence for searching relevant passages: "

DEFAULT_MODELS = [
    "BAAI/bge-small-en-v1.5",
    "intfloat/multilingual-e5-small",
    "BAAI/bge-m3",
]

# `--candidates`: the shipped embedder against the two newer small multilingual models.
# google/embeddinggemma-300m is gated: accept its licence on Hugging Face and log in first.
CANDIDATE_MODELS = [
    "BAAI/bge-small-en-v1.5",
    "Qwen/Qwen3-Embedding-0.6B",
    "google/embeddinggemma-300m",
]


def _prefixes(model: str, bge_instruction: bool) -> tuple[str, str]:
    query_prefix, passage_prefix = MODEL_PREFIXES.get(model, ("", ""))
    if bge_instruction and model.startswith("BAAI/bge-") and "m3" not in model:
        query_prefix = BGE_QUERY_INSTRUCTION
    return query_prefix, passage_prefix


def evaluate(
    model_name: str,
    texts: list[str],
    ids: list[str],
    queries,
    qrels,
    vi_rows: list[dict],
    device: str,
    batch_size: int,
    bge_instruction: bool,
) -> dict:
    from sentence_transformers import SentenceTransformer

    query_prefix, passage_prefix = _prefixes(model_name, bge_instruction)

    t0 = time.time()
    model = SentenceTransformer(model_name, device=device)
    load_seconds = time.time() - t0

    t0 = time.time()
    corpus = model.encode(
        [passage_prefix + t for t in texts],
        batch_size=batch_size,
        normalize_embeddings=True,
        show_progress_bar=False,
    )
    embed_seconds = time.time() - t0

    def encode_queries(items: list[str]) -> np.ndarray:
        return model.encode(
            [query_prefix + q for q in items],
            batch_size=batch_size,
            normalize_embeddings=True,
            show_progress_bar=False,
        )

    # ── English golden set ────────────────────────────────────────────────────
    q_vectors = encode_queries([q.question for q in queries])
    ranked = np.argsort(-(q_vectors @ corpus.T), axis=1)[:, :10]
    # Group-aware relevance: after final/chunk-splitting the pieces of one gold chunk count once.
    rows = [
        (qrels[q.query_id].relevance(), [ids[j] for j in ranked[i]])
        for i, q in enumerate(queries)
    ]
    english: dict[str, dict] = {}
    for k in (5, 10):
        english[str(k)] = {
            "recall": sum(recall_at_k(g, d, k) for g, d in rows) / len(rows),
            "doc_hit": sum(doc_hit_at_k(g, d, k) for g, d in rows) / len(rows),
            "mrr": sum(mrr(g, d[:k]) for g, d in rows) / len(rows),
            "ndcg": sum(ndcg_at_k(g, d, k) for g, d in rows) / len(rows),
        }

    # ── Cross-lingual ─────────────────────────────────────────────────────────
    # Each VI question is paired with its English twin, so the comparison is
    # "does the Vietnamese query find what its translation finds" — which is
    # exactly the question of whether the app's translation step can be dropped.
    cross = None
    if vi_rows:
        vi_vectors = encode_queries([r["question"] for r in vi_rows])
        en_vectors = encode_queries([r["en_equivalent"] for r in vi_rows])
        vi_top = np.argsort(-(vi_vectors @ corpus.T), axis=1)[:, :5]
        en_top = np.argsort(-(en_vectors @ corpus.T), axis=1)[:, :5]
        cross = {
            "chunk_overlap_at_5": float(
                np.mean(
                    [
                        len(set(vi_top[i]) & set(en_top[i])) / 5
                        for i in range(len(vi_rows))
                    ]
                )
            ),
            "same_document_at_5": float(
                np.mean(
                    [
                        len(
                            {doc_id_of(ids[j]) for j in vi_top[i]}
                            & {doc_id_of(ids[j]) for j in en_top[i]}
                        )
                        > 0
                        for i in range(len(vi_rows))
                    ]
                )
            ),
            "cosine_vi_en_query": float((vi_vectors @ en_vectors.T).diagonal().mean()),
            "queries": len(vi_rows),
        }

    return {
        "model": model_name,
        "device": device,
        "dim": int(corpus.shape[1]),
        "query_prefix": query_prefix,
        "passage_prefix": passage_prefix,
        "load_seconds": round(load_seconds, 1),
        "embed_seconds": round(embed_seconds, 1),
        "chunks": len(texts),
        "english": english,
        "cross_lingual": cross,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--models", nargs="+", default=None)
    parser.add_argument(
        "--candidates",
        action="store_true",
        help="compare the shipped embedder with Qwen3-Embedding-0.6B and EmbeddingGemma-300m",
    )
    parser.add_argument(
        "--device",
        default="cpu",
        help="cpu (default) / mps / cuda. The default is deliberate — an unpinned run "
        "grabs CUDA and OOMs on a small card.",
    )
    parser.add_argument("--batch-size", type=int, default=16)
    parser.add_argument(
        "--bge-instruction",
        action="store_true",
        help="prepend bge-v1.5's documented retrieval instruction to queries",
    )
    parser.add_argument(
        "--enriched", type=Path, default=_ROOT / "eval" / "outputs" / "enriched_neural"
    )
    parser.add_argument("--out", type=Path, default=None)
    args = parser.parse_args()
    if args.models and args.candidates:
        parser.error("--models and --candidates are exclusive")
    args.models = args.models or (CANDIDATE_MODELS if args.candidates else DEFAULT_MODELS)

    if not args.enriched.exists():
        raise SystemExit(
            f"{args.enriched} not found — run `python -m eval.build_indexes` first."
        )

    chunks = load_all_chunks(args.enriched)
    texts = [c["text"] for c in chunks]
    ids = [c["chunk_id"] for c in chunks]

    queries = load_queries(_ROOT / "eval" / "data" / "queries.jsonl")
    qrels = load_qrels(_ROOT / "eval" / "data" / "qrels.jsonl")

    vi_path = _ROOT / "eval" / "data" / "queries_vi.jsonl"
    vi_rows: list[dict] = []
    if vi_path.exists():
        vi_rows = [
            json.loads(line)
            for line in vi_path.read_text(encoding="utf-8").splitlines()
            if line.strip()
        ]
        vi_rows = [r for r in vi_rows if r.get("en_equivalent")]
    else:
        print(
            f"[WARN] {vi_path} missing — the cross-lingual comparison will be skipped."
        )
        print(
            "       It lives on branch final/answer-quality; merge or cherry-pick it first."
        )

    print(
        f"corpus: {len(texts)} chunks | EN golden: {len(queries)} | VI paired: {len(vi_rows)}"
    )
    print(f"device: {args.device}\n")

    results = []
    for name in args.models:
        print(f"── {name}")
        try:
            result = evaluate(
                name,
                texts,
                ids,
                queries,
                qrels,
                vi_rows,
                args.device,
                args.batch_size,
                args.bge_instruction,
            )
        except (
            Exception
        ) as exc:  # a missing model or an OOM must not lose the earlier results
            print(f"   FAILED: {type(exc).__name__}: {exc}\n")
            results.append({"model": name, "error": f"{type(exc).__name__}: {exc}"})
            continue

        results.append(result)
        print(
            f"   dim={result['dim']}  embedded {result['chunks']} chunks in {result['embed_seconds']:.0f}s"
        )
        if result["query_prefix"] or result["passage_prefix"]:
            print(
                f"   prefixes: query={result['query_prefix']!r} passage={result['passage_prefix']!r}"
            )
        for k in ("5", "10"):
            m = result["english"][k]
            print(
                f"   EN k={k}: recall={m['recall']:.4f} doc-hit={m['doc_hit']:.4f} "
                f"mrr={m['mrr']:.4f} ndcg={m['ndcg']:.4f}"
            )
        if result["cross_lingual"]:
            c = result["cross_lingual"]
            print(
                f"   VI→EN: chunk-overlap@5={c['chunk_overlap_at_5']:.3f} "
                f"same-doc@5={c['same_document_at_5']:.3f} "
                f"cos(VI,EN query)={c['cosine_vi_en_query']:.3f}"
            )
        print()

    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(
            json.dumps({"results": results}, indent=2), encoding="utf-8"
        )
        print(f"Wrote {args.out}")


if __name__ == "__main__":
    main()
