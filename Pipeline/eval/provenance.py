from __future__ import annotations

import hashlib
import json
import platform
import sqlite3
import subprocess
from pathlib import Path


_GIT_FAILED = object()


def _git(*args: str, cwd: Path):
    """Returns the command's stdout, or `_GIT_FAILED` if git could not answer.

    Empty stdout is a real answer -- `git status --porcelain` prints nothing for a
    clean tree -- so it must not be conflated with failure, or a clean tree reports
    its dirty flag as unknown.
    """
    try:
        out = subprocess.run(
            ["git", *args], cwd=cwd, capture_output=True, text=True, timeout=10
        )
    except (OSError, subprocess.SubprocessError):
        return _GIT_FAILED
    if out.returncode != 0:
        return _GIT_FAILED
    return out.stdout.strip()


def git_state(repo_dir: Path) -> dict:
    """Commit the eval ran at, plus whether the tree was dirty.

    A result produced from a dirty tree is not reproducible from a commit alone,
    so the flag has to travel with the numbers.
    """
    commit = _git("rev-parse", "HEAD", cwd=repo_dir)
    branch = _git("rev-parse", "--abbrev-ref", "HEAD", cwd=repo_dir)
    status = _git("status", "--porcelain", cwd=repo_dir)
    return {
        "commit": None if commit is _GIT_FAILED else commit,
        "branch": None if branch is _GIT_FAILED else branch,
        "dirty": None if status is _GIT_FAILED else bool(status),
    }


def file_digest(path: Path) -> str | None:
    if not path.exists():
        return None
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def index_fingerprint(db_path: Path) -> dict:
    """Identify the index a score was produced against.

    Without this, a result JSON cannot be told apart from one computed over a
    different corpus -- which is exactly how the 9-doc/39-doc mismatch went
    unnoticed (see Docs/Eval-Integrity-Finding.md).
    """
    info: dict = {
        "path": str(db_path),
        "exists": db_path.exists(),
        "sha256": file_digest(db_path),
        "size_bytes": db_path.stat().st_size if db_path.exists() else None,
        "chunk_count": None,
        "doc_count": None,
        "tables": [],
    }
    if not db_path.exists():
        return info
    try:
        conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
        info["tables"] = sorted(
            r[0]
            for r in conn.execute(
                "SELECT name FROM sqlite_master WHERE type IN ('table','view')"
            )
        )
        if "chunks" in info["tables"]:
            info["chunk_count"] = conn.execute("SELECT count(*) FROM chunks").fetchone()[0]
            info["doc_count"] = conn.execute(
                "SELECT count(DISTINCT doc_id) FROM chunks"
            ).fetchone()[0]
        conn.close()
    except sqlite3.Error as exc:  # a corrupt or half-built index must not be silent
        info["error"] = str(exc)
    return info


def corpus_fingerprint(source_dir: Path) -> dict:
    files = sorted(source_dir.glob("*.json")) if source_dir.exists() else []
    return {
        "path": str(source_dir),
        "exists": source_dir.exists(),
        "file_count": len(files),
        "files_sha256": hashlib.sha256(
            "".join(f"{p.name}:{file_digest(p)}" for p in files).encode()
        ).hexdigest()
        if files
        else None,
    }


def qrels_coverage(qrels: dict, index_db: Path) -> dict:
    """How much of the golden set the index can actually answer.

    coverage < 1.0 caps recall at coverage -- a low score then means "the gold
    chunk is not in the index", not "retrieval is bad".
    """
    gold: set[str] = set()
    for item in qrels.values():
        gold.update(item.relevant_chunk_ids)
    result = {
        "gold_chunk_ids": len(gold),
        "present_in_index": None,
        "coverage": None,
        "max_achievable_recall": None,
    }
    if not gold or not index_db.exists():
        return result
    try:
        conn = sqlite3.connect(f"file:{index_db}?mode=ro", uri=True)
        names = {r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        if "chunks" not in names:
            conn.close()
            return result
        indexed = {r[0] for r in conn.execute("SELECT chunk_id FROM chunks")}
        conn.close()
    except sqlite3.Error:
        return result
    present = len(gold & indexed)
    result["present_in_index"] = present
    result["coverage"] = present / len(gold)
    result["max_achievable_recall"] = result["coverage"]
    return result


def environment() -> dict:
    versions: dict[str, str] = {}
    for mod in ("numpy", "sentence_transformers", "sqlite_vec", "torch", "transformers"):
        try:
            versions[mod] = __import__(mod).__version__
        except Exception:
            versions[mod] = "unavailable"
    return {
        "python": platform.python_version(),
        "platform": platform.platform(),
        "packages": versions,
        "sqlite": sqlite3.sqlite_version,
    }


def config_digest(cfg: dict) -> str:
    return hashlib.sha256(
        json.dumps(cfg, sort_keys=True, ensure_ascii=False).encode()
    ).hexdigest()
