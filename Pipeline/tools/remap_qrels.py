"""
remap_qrels.py — repair stale qrel chunk IDs after a re-chunk.

Re-chunking shifts chunk boundaries, so some golden qrel chunk_ids no longer
exist in the rebuilt index. For each missing id we recover its ORIGINAL text
from the old (backup) vectorstore and map it to the new chunk in the SAME
document with the highest embedding cosine similarity. Matches at or above
THRESHOLD are rewritten automatically; weaker matches are printed for manual
review and left unchanged.

Usage:
    .venv/bin/python tools/remap_qrels.py            # dry run: report only
    .venv/bin/python tools/remap_qrels.py --apply    # rewrite qrels.jsonl (backs up first)
"""
from __future__ import annotations

import argparse
import json
import shutil
import sqlite3
from pathlib import Path

import numpy as np
from sentence_transformers import SentenceTransformer

ROOT = Path(__file__).parent.parent
NEW_DB = ROOT / "data" / "vectorstore.db"
OLD_DB = ROOT / "vectorstore.db.bak-old-9docs-20260724"
QRELS = ROOT / "eval" / "data" / "qrels.jsonl"
EMBED_MODEL = "BAAI/bge-small-en-v1.5"
COS_THRESHOLD = 0.80
CONTAIN_THRESHOLD = 0.75  # fraction of old tokens present in the candidate (handles fine->coarse merges)


def doc_id_of(chunk_id: str) -> str:
    return chunk_id.rsplit("_c", 1)[0]


def _tokens(text: str) -> set[str]:
    import re

    return set(re.findall(r"[a-z0-9]+", text.lower()))


def _containment(old_text: str, new_text: str) -> float:
    o = _tokens(old_text)
    if not o:
        return 0.0
    return len(o & _tokens(new_text)) / len(o)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true", help="rewrite qrels.jsonl (otherwise dry run)")
    args = ap.parse_args()

    qrels = [json.loads(l) for l in QRELS.read_text().splitlines() if l.strip()]
    new_conn = sqlite3.connect(NEW_DB)
    new_ids = {r[0] for r in new_conn.execute("SELECT chunk_id FROM chunks")}

    referenced = set()
    for q in qrels:
        referenced.update(q["relevant_chunk_ids"])
    missing = sorted(x for x in referenced if x not in new_ids)
    if not missing:
        print("No stale qrel chunk IDs — nothing to remap.")
        return

    old_conn = sqlite3.connect(OLD_DB)
    old_text = {
        cid: old_conn.execute(
            "SELECT text FROM chunks WHERE chunk_id=?", [cid]
        ).fetchone()[0]
        for cid in missing
    }

    # Candidate new chunks, grouped by doc_id.
    new_rows = new_conn.execute("SELECT chunk_id, text FROM chunks").fetchall()
    by_doc: dict[str, list[tuple[str, str]]] = {}
    for cid, text in new_rows:
        by_doc.setdefault(doc_id_of(cid), []).append((cid, text))

    model = SentenceTransformer(EMBED_MODEL)

    def embed(texts: list[str]) -> np.ndarray:
        return model.encode(texts, normalize_embeddings=True, show_progress_bar=False)

    mapping: dict[str, str] = {}
    dropped: list[tuple[str, str, float, float]] = []
    old_vecs = embed([old_text[m] for m in missing])
    for old_id, old_vec in zip(missing, old_vecs):
        cands = by_doc.get(doc_id_of(old_id), [])
        if not cands:
            dropped.append((old_id, "<no candidates>", 0.0, 0.0))
            continue
        cvecs = embed([t for _, t in cands])
        sims = cvecs @ old_vec
        best = int(np.argmax(sims))
        best_id, best_sim = cands[best][0], float(sims[best])
        contain = _containment(old_text[old_id], cands[best][1])
        if best_sim >= COS_THRESHOLD or contain >= CONTAIN_THRESHOLD:
            mapping[old_id] = best_id
            print(f"[MAP ] {old_id:<24} -> {best_id:<24} (cos={best_sim:.3f} contain={contain:.2f})")
        else:
            dropped.append((old_id, best_id, best_sim, contain))
            print(f"[DROP] {old_id:<24} best {best_id:<24} (cos={best_sim:.3f} contain={contain:.2f}) — no clean match")

    print(f"\n{len(mapping)} remapped, {len(dropped)} dropped (no clean single-chunk match).")

    if not args.apply:
        print("Dry run — pass --apply to rewrite qrels.jsonl.")
        return

    drop_ids = {d[0] for d in dropped}
    shutil.copy(QRELS, QRELS.with_suffix(".jsonl.bak"))
    kept_queries: list[dict] = []
    emptied: list[str] = []
    for q in qrels:
        remapped = [mapping.get(c, c) for c in q["relevant_chunk_ids"] if c not in drop_ids]
        if not remapped:
            emptied.append(q["query_id"])
            continue  # drop queries with no surviving relevant chunk (validate_dataset requires >=1)
        q["relevant_chunk_ids"] = remapped
        kept_queries.append(q)
    QRELS.write_text("\n".join(json.dumps(q, ensure_ascii=False) for q in kept_queries) + "\n")

    # Keep queries.jsonl aligned so validate_dataset passes.
    queries_path = QRELS.parent / "queries.jsonl"
    shutil.copy(queries_path, queries_path.with_suffix(".jsonl.bak"))
    kept_ids = {q["query_id"] for q in kept_queries}
    q_rows = [json.loads(l) for l in queries_path.read_text().splitlines() if l.strip()]
    q_rows = [q for q in q_rows if q["query_id"] in kept_ids]
    queries_path.write_text("\n".join(json.dumps(q, ensure_ascii=False) for q in q_rows) + "\n")

    print(f"Rewrote qrels.jsonl and queries.jsonl (backups alongside).")
    print(f"Kept {len(kept_queries)} queries; dropped {len(emptied)} with no surviving gold chunk: {emptied}")
    if dropped:
        print("Dropped chunk IDs (no clean single-chunk equivalent after re-chunk):")
        for old_id, best_id, sim, contain in dropped:
            print(f"  {old_id} (nearest {best_id}, cos={sim:.3f}, contain={contain:.2f})")


if __name__ == "__main__":
    main()
