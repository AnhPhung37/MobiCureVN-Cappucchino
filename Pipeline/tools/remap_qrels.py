"""remap_qrels.py — repair golden-set chunk IDs after the corpus is re-chunked.

Chunk IDs are `<doc_id>_c<chunk_index>`, so any re-chunk renumbers them and the golden set
starts pointing at the wrong passages. Two modes:

--from-split-provenance   (after ingestion/split_oversized.py)
    Exact. Every chunk records `source_chunk_index`, the chunk it came from, so each old gold ID
    maps to ALL the pieces of that chunk, written as one relevance group. The original label said
    "this chunk answers the question"; after a split that means "any of its pieces does", and
    eval.metrics_ir scores groups that way — splitting a gold chunk into three does not cut its
    recall to a third, and no piece is picked by a similarity measure that would favour one
    retriever. Queries already carrying `relevant_groups` were remapped before and are left alone.

--old-db OLD --new-db NEW   (after re-chunking from Markdown, where there is no provenance)
    Approximate. Each missing ID is mapped to the most similar chunk in the same document by
    embedding cosine or token containment; weak matches are dropped and listed for review.

Nothing is written without --apply; qrels.jsonl and queries.jsonl get timestamped .bak copies, and a query
left with no gold chunk is dropped from both (validate_dataset requires at least one).

Usage (from Pipeline/):
    python -m tools.remap_qrels --from-split-provenance            # dry run
    python -m tools.remap_qrels --from-split-provenance --apply
    python -m tools.remap_qrels --old-db old.db --new-db data/vectorstore.db --apply
"""
from __future__ import annotations

import argparse
import csv
import json
import re
import shutil
import sqlite3
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).parent.parent
QRELS = ROOT / "eval" / "data" / "qrels.jsonl"
CHUNKS_DIR = ROOT / "data" / "neural_chunks"
REGISTRY = ROOT / "data" / "registry.csv"
EMBED_MODEL = "BAAI/bge-small-en-v1.5"
COS_THRESHOLD = 0.80
CONTAIN_THRESHOLD = 0.75  # fraction of old tokens present in the candidate (handles fine->coarse merges)


def doc_id_of(chunk_id: str) -> str:
    head, sep, tail = chunk_id.rpartition("_c")
    return head if sep and tail.isdigit() else chunk_id


def chunk_id(doc_id: str, index: int) -> str:
    """Mirrors ingestion/enrich_chunks.py."""
    return f"{doc_id}_c{index:03d}"


def split_provenance_map(chunks_dir: Path, registry_path: Path) -> dict[str, list[str]]:
    """old chunk ID -> new chunk IDs of every piece that came from it."""
    with open(registry_path, newline="", encoding="utf-8") as f:
        doc_ids = {row["title"].strip(): row["doc_id"].strip() for row in csv.DictReader(f)}
    mapping: dict[str, list[str]] = defaultdict(list)
    for path in sorted(chunks_dir.glob("*.json")):
        doc_id = doc_ids.get(path.stem)
        if doc_id is None:
            continue
        for chunk in json.loads(path.read_text(encoding="utf-8")).get("chunks", []):
            if "source_chunk_index" not in chunk:
                raise SystemExit(
                    f"{path.name}: chunk {chunk.get('chunk_index')} has no source_chunk_index — "
                    "run ingestion/split_oversized.py first, or use the --old-db mode"
                )
            mapping[chunk_id(doc_id, chunk["source_chunk_index"])].append(chunk_id(doc_id, chunk["chunk_index"]))
    return dict(mapping)


def remap_by_provenance(qrels: list[dict], mapping: dict[str, list[str]]) -> tuple[list[dict], list[str], list[str]]:
    """Returns (qrels, dropped chunk IDs, queries left untouched because already grouped)."""
    dropped: list[str] = []
    already: list[str] = []
    out: list[dict] = []
    for q in qrels:
        if q.get("relevant_groups"):
            already.append(q["query_id"])
            out.append(q)
            continue
        groups = []
        for old in q["relevant_chunk_ids"]:
            pieces = mapping.get(old)
            if pieces:
                groups.append(pieces)
            else:
                dropped.append(old)
        out.append({**q, "relevant_chunk_ids": [cid for g in groups for cid in g], "relevant_groups": groups})
    return out, dropped, already


def _tokens(text: str) -> set[str]:
    return set(re.findall(r"[a-z0-9]+", text.lower()))


def _containment(old_text: str, new_text: str) -> float:
    o = _tokens(old_text)
    return len(o & _tokens(new_text)) / len(o) if o else 0.0


def remap_by_similarity(qrels: list[dict], old_db: Path, new_db: Path) -> tuple[list[dict], list[str]]:
    import numpy as np
    from sentence_transformers import SentenceTransformer

    new_conn = sqlite3.connect(new_db)
    new_rows = new_conn.execute("SELECT chunk_id, text FROM chunks").fetchall()
    new_ids = {cid for cid, _ in new_rows}
    missing = sorted({c for q in qrels for c in q["relevant_chunk_ids"]} - new_ids)
    if not missing:
        print("No stale qrel chunk IDs — nothing to remap.")
        return qrels, []

    old_conn = sqlite3.connect(old_db)
    old_text = {}
    for cid in missing:
        row = old_conn.execute("SELECT text FROM chunks WHERE chunk_id=?", [cid]).fetchone()
        if row:
            old_text[cid] = row[0]
    by_doc: dict[str, list[tuple[str, str]]] = defaultdict(list)
    for cid, text in new_rows:
        by_doc[doc_id_of(cid)].append((cid, text))

    model = SentenceTransformer(EMBED_MODEL, device="cpu")
    embed = lambda texts: model.encode(texts, normalize_embeddings=True, show_progress_bar=False)  # noqa: E731

    mapping: dict[str, str] = {}
    dropped: list[str] = []
    for old_id in missing:
        cands = by_doc.get(doc_id_of(old_id), [])
        if old_id not in old_text or not cands:
            dropped.append(old_id)
            print(f"[DROP] {old_id:<24} no text in the old index or no candidates")
            continue
        sims = embed([t for _, t in cands]) @ embed([old_text[old_id]])[0]
        best = int(np.argmax(sims))
        best_id, best_sim = cands[best][0], float(sims[best])
        contain = _containment(old_text[old_id], cands[best][1])
        if best_sim >= COS_THRESHOLD or contain >= CONTAIN_THRESHOLD:
            mapping[old_id] = best_id
            print(f"[MAP ] {old_id:<24} -> {best_id:<24} (cos={best_sim:.3f} contain={contain:.2f})")
        else:
            dropped.append(old_id)
            print(f"[DROP] {old_id:<24} best {best_id:<24} (cos={best_sim:.3f} contain={contain:.2f})")

    out = []
    for q in qrels:
        ids = [mapping.get(c, c) for c in q["relevant_chunk_ids"] if c not in dropped]
        out.append({**q, "relevant_chunk_ids": ids})
    return out, dropped


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--from-split-provenance", action="store_true")
    ap.add_argument("--chunks-dir", type=Path, default=CHUNKS_DIR)
    ap.add_argument("--registry", type=Path, default=REGISTRY)
    ap.add_argument("--old-db", type=Path, help="index built from the corpus the golden set was labelled against")
    ap.add_argument("--new-db", type=Path, help="index built from the re-chunked corpus")
    ap.add_argument("--qrels", type=Path, default=QRELS)
    ap.add_argument("--apply", action="store_true", help="rewrite qrels.jsonl and queries.jsonl (otherwise dry run)")
    args = ap.parse_args()

    qrels = [json.loads(line) for line in args.qrels.read_text(encoding="utf-8").splitlines() if line.strip()]
    if args.from_split_provenance:
        remapped, dropped, already = remap_by_provenance(qrels, split_provenance_map(args.chunks_dir, args.registry))
        sizes = [len(g) for q in remapped for g in q.get("relevant_groups", [])]
        print(
            f"{len(qrels) - len(already)} queries remapped by provenance, {len(already)} already grouped; "
            f"{len(dropped)} gold IDs with no pieces; groups of {min(sizes, default=0)}-{max(sizes, default=0)} pieces "
            f"({sum(1 for n in sizes if n > 1)} gold chunks were split)"
        )
    elif args.old_db and args.new_db:
        remapped, dropped = remap_by_similarity(qrels, args.old_db, args.new_db)
        print(f"\n{len(dropped)} dropped (no clean single-chunk match).")
    else:
        ap.error("choose --from-split-provenance, or give both --old-db and --new-db")

    kept = [q for q in remapped if q["relevant_chunk_ids"]]
    emptied = [q["query_id"] for q in remapped if not q["relevant_chunk_ids"]]
    if dropped:
        print("Dropped gold chunk IDs:", ", ".join(dropped))
    if emptied:
        print(f"Queries left with no gold chunk (would be dropped): {emptied}")

    if not args.apply:
        print("Dry run — pass --apply to rewrite qrels.jsonl.")
        return

    # Timestamped, so a backup never overwrites an earlier one (two are committed already).
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    shutil.copy(args.qrels, args.qrels.with_name(f"{args.qrels.name}.bak-{stamp}"))
    args.qrels.write_text("".join(json.dumps(q, ensure_ascii=False) + "\n" for q in kept), encoding="utf-8")
    queries_path = args.qrels.parent / "queries.jsonl"
    if emptied and queries_path.exists():
        shutil.copy(queries_path, queries_path.with_name(f"{queries_path.name}.bak-{stamp}"))
        rows = [json.loads(line) for line in queries_path.read_text(encoding="utf-8").splitlines() if line.strip()]
        keep_ids = {q["query_id"] for q in kept}
        queries_path.write_text(
            "".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows if r["query_id"] in keep_ids), encoding="utf-8"
        )
    print(f"Rewrote {args.qrels.name}: kept {len(kept)} queries (backup alongside).")


if __name__ == "__main__":
    main()
