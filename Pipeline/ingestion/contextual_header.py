"""Contextual header for chunk embeddings: "<document title> › <section>" above the chunk text.

A chunk is embedded on its own, so a passage such as "Empty it when it is a third full" carries no
trace of the stoma-care leaflet it came from, and a question that names the topic has to find it
on the passage's words alone. Prefixing the document title and section heading to the text that
is EMBEDDED gives each vector that context — contextual retrieval without an LLM, since the header
is metadata the corpus already has.

Only the embedding input changes. The stored `text`, which FTS5 indexes, the prompt quotes and the
UI shows, stays the chunk exactly as chunked; queries are embedded unchanged.

Shared by ingestion/build_index.py (the index the app ships) and eval/index_builder.py, so the
evaluated index and the shipped one embed the same strings.
"""

from __future__ import annotations

import csv
from pathlib import Path

SEPARATOR = " › "


def humanize_title(title: str) -> str:
    """Registry titles are file stems ("Bowel_Cancer_UK_About_Stoma_Reversal_2024")."""
    return " ".join(title.replace("_", " ").split())


def load_titles(registry_path: Path) -> dict[str, str]:
    with open(registry_path, newline="", encoding="utf-8") as f:
        return {row["doc_id"].strip(): humanize_title(row["title"]) for row in csv.DictReader(f)}


def embedding_text(chunk: dict, titles: dict[str, str] | None) -> str:
    """The string embedded for `chunk`: the plain text when `titles` is None, else header + text."""
    if titles is None:
        return chunk["text"]
    section = (chunk.get("section") or "").strip().lstrip("#").strip()
    header = SEPARATOR.join(part for part in (titles.get(chunk["doc_id"], ""), section) if part)
    return f"{header}\n\n{chunk['text']}" if header else chunk["text"]
