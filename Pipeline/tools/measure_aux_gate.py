#!/usr/bin/env python3
"""How often does the post-answer gate let a turn through to the two LLM passes?

`SessionFactExtractor.statesDurableFact` decides whether a turn runs fact extraction and
profile-update extraction (two full generations after every answer). This tool parses the cue
list out of the Swift source -- so the numbers always describe the code as committed -- mirrors
its whole-word matching, and reports the fire rate over question sets.

The orchestrator passes the TRANSLATED ENGLISH text to the gate, so the rates that describe
production are the English golden set and the English equivalents of the Vietnamese questions.

    python -m tools.measure_aux_gate
    git show final/answer-quality:Pipeline/eval/data/queries_vi.jsonl > /tmp/queries_vi.jsonl
    python -m tools.measure_aux_gate --texts eval/data/queries.jsonl:question \\
        /tmp/queries_vi.jsonl:en_equivalent /tmp/queries_vi.jsonl:question
"""

from __future__ import annotations

import argparse
import collections
import json
import re
import unicodedata
from pathlib import Path

_ROOT = Path(__file__).resolve().parent.parent
_SWIFT = (
    _ROOT.parent
    / "App"
    / "Backend"
    / "Services"
    / "SessionMemory"
    / "SessionFactExtractor.swift"
)


def load_cues(path: Path = _SWIFT) -> list[list[str]]:
    source = path.read_text(encoding="utf-8")
    match = re.search(
        r"disclosureCues: \[\[String\]\] = \[(.*?)\]\.map", source, flags=re.DOTALL
    )
    if not match:
        raise SystemExit(f"could not find disclosureCues in {path}")
    body = re.sub(r"//[^\n]*", "", match.group(1))
    return [cue.split(" ") for cue in re.findall(r'"([^"]*)"', body)]


def gate_words(text: str) -> list[str]:
    """Mirrors `gateWords(in:)`: NFC, lowercase, typographic apostrophe folded, split on
    anything that is not a letter, digit or apostrophe, apostrophes trimmed."""
    text = unicodedata.normalize("NFC", text).lower().replace("’", "'")
    parts = re.split(r"[^\w']|_", text)
    return [p.strip("'") for p in parts if p.strip("'")]


def fired_cues(text: str, cues: list[list[str]]) -> list[str]:
    words = gate_words(text)
    hits = []
    for cue in cues:
        n = len(cue)
        if any(words[i : i + n] == cue for i in range(len(words) - n + 1)):
            hits.append(" ".join(cue))
    return hits


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--texts",
        nargs="+",
        default=[str(_ROOT / "eval" / "data" / "queries.jsonl") + ":question"],
        help="JSONL_PATH:FIELD, one per question set",
    )
    parser.add_argument("--examples", type=int, default=5)
    args = parser.parse_args()

    cues = load_cues()
    print(f"{len(cues)} cues parsed from {_SWIFT.name}\n")
    for spec in args.texts:
        path, _, field = spec.rpartition(":")
        rows = [
            json.loads(line)
            for line in Path(path).read_text(encoding="utf-8").splitlines()
            if line.strip()
        ]
        texts = [row[field] for row in rows if row.get(field)]
        fired = [(text, fired_cues(text, cues)) for text in texts]
        fired = [(text, hits) for text, hits in fired if hits]
        counts = collections.Counter(cue for _, hits in fired for cue in hits)
        print(
            f"{Path(path).name}:{field}  fires on {len(fired)}/{len(texts)}  top cues {counts.most_common(6)}"
        )
        for text, hits in fired[: args.examples]:
            print(f"    {hits}  {text[:90]}")
        print()


if __name__ == "__main__":
    main()
