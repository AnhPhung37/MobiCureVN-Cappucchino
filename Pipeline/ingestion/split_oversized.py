"""Stage 3b: split chunks that exceed the embedder's context window.

The retrieval embedder (`BAAI/bge-small-en-v1.5`) has a 512-token window. Anything
past that in a chunk is **silently never embedded** — the passage is only ever
retrievable by its opening, and the rest of it is dead weight in the index. Measured
on the shipped corpus: 17.7% of chunks exceed 512 tokens and the largest is ~13,664,
i.e. 26x the window.

The same chunks then break prompt assembly downstream, because a chunk larger than
the whole context budget cannot be packed at all (see Docs/BE/Context-Budget-Finding.md).

This stage is deliberately separate from `chunk.py`, and works on the chunk JSON
rather than the source Markdown, so it can be applied to an existing corpus without
re-running the neural chunker (a ~1GB model download) and so it is independent of
which chunker produced the input.

Splitting prefers the largest boundary that works — paragraph, then sentence, then a
hard word cut — because a cut inside a sentence costs more meaning than one between
paragraphs. Consecutive pieces overlap slightly so a fact spanning a cut survives in
at least one piece whole.

Usage:
    python -m ingestion.split_oversized                    # data/neural_chunks in place
    python -m ingestion.split_oversized --dir data/semantic_chunks
    python -m ingestion.split_oversized --dry-run          # report only, write nothing
"""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

_ROOT = Path(__file__).parent.parent

# The embedder window is 512; leave room for the [CLS]/[SEP] the tokenizer adds, plus
# slack for the fact that a split point is chosen on text, not on tokens.
MAX_CHUNK_TOKENS = 480

# Carried from the end of one piece into the start of the next. A fact that straddles a
# split ("...contact the stoma nurse if | the redness spreads.") is otherwise present in
# neither piece as a whole statement.
OVERLAP_TOKENS = 48

# Below this a piece cannot stand alone as a retrievable passage; it is merged back into
# the previous one instead of being emitted as a fragment.
MIN_PIECE_TOKENS = 40

_PARAGRAPH_RE = re.compile(r"\n\s*\n")
_SENTENCE_RE = re.compile(r"(?<=[.!?])\s+")

_tokenizer = None


def _count_tokens(text: str) -> int:
    """Real tokeniser count, not a word-count estimate.

    The estimate this replaces (`words * ratio`) under-counts medical prose badly —
    measured median on this corpus is 1.554 tokens/word against a 1.4 assumption — and
    the whole point of this stage is to guarantee a ceiling, which an estimate cannot do.
    """
    global _tokenizer
    if _tokenizer is None:
        from transformers import AutoTokenizer

        _tokenizer = AutoTokenizer.from_pretrained("BAAI/bge-small-en-v1.5")
    return len(_tokenizer.encode(text, add_special_tokens=False))


def _segments(text: str) -> list[str]:
    """Split into the smallest units a cut may fall between.

    Paragraphs first; a paragraph that is itself over the limit is broken into
    sentences; a sentence over the limit (a table row, a run-on list) is cut on words.
    """
    units: list[str] = []
    for para in _PARAGRAPH_RE.split(text):
        para = para.strip()
        if not para:
            continue
        if _count_tokens(para) <= MAX_CHUNK_TOKENS:
            units.append(para)
            continue
        for sent in _SENTENCE_RE.split(para):
            sent = sent.strip()
            if not sent:
                continue
            if _count_tokens(sent) <= MAX_CHUNK_TOKENS:
                units.append(sent)
                continue
            # Still too long: hard-cut on the tokeniser itself. Rare, and always a
            # malformed passage (an unwrapped table, usually) rather than prose. Cutting
            # on words here was the original mistake -- a 288-word slice is ~450 tokens
            # for prose but far more for clinical text, so the ceiling leaked.
            units.extend(_hard_split(sent, MAX_CHUNK_TOKENS))
    return units


def _hard_split(text: str, limit: int) -> list[str]:
    """Cut `text` into token-exact windows. The ceiling this stage promises has to be
    guaranteed by the tokeniser, not approximated from word counts."""
    global _tokenizer
    if _tokenizer is None:
        from transformers import AutoTokenizer

        _tokenizer = AutoTokenizer.from_pretrained("BAAI/bge-small-en-v1.5")
    ids = _tokenizer.encode(text, add_special_tokens=False)
    if len(ids) <= limit:
        return [text]
    return [
        _tokenizer.decode(ids[i : i + limit], skip_special_tokens=True)
        for i in range(0, len(ids), limit)
    ]


def _overlap_tail(text: str, tokens: int) -> str:
    """The last `tokens`-ish worth of text, cut at a sentence boundary where possible."""
    if tokens <= 0:
        return ""
    sentences = _SENTENCE_RE.split(text)
    tail: list[str] = []
    total = 0
    for sent in reversed(sentences):
        cost = _count_tokens(sent)
        if total + cost > tokens and tail:
            break
        tail.insert(0, sent)
        total += cost
    return " ".join(tail).strip()


def split_text(text: str) -> list[str]:
    """Split `text` into pieces each at or below MAX_CHUNK_TOKENS."""
    if _count_tokens(text) <= MAX_CHUNK_TOKENS:
        return [text]

    pieces: list[str] = []
    current: list[str] = []
    current_tokens = 0

    for unit in _segments(text):
        cost = _count_tokens(unit)
        if current and current_tokens + cost > MAX_CHUNK_TOKENS:
            piece = "\n\n".join(current).strip()
            pieces.append(piece)
            carry = _overlap_tail(piece, OVERLAP_TOKENS)
            current = [carry] if carry else []
            current_tokens = _count_tokens(carry) if carry else 0
        current.append(unit)
        current_tokens += cost

    if current:
        piece = "\n\n".join(current).strip()
        # A trailing sliver is worse than a slightly oversized predecessor: it retrieves
        # as an independent passage while saying almost nothing.
        if pieces and _count_tokens(piece) < MIN_PIECE_TOKENS:
            pieces[-1] = pieces[-1] + "\n\n" + piece
        else:
            pieces.append(piece)

    # Guarantee the ceiling. Merging a sliver back, or carrying an overlap into a piece
    # that then grew, can push one over; this stage is worthless if its promise is only
    # usually kept, so enforce it on the tokeniser as the last step.
    guaranteed: list[str] = []
    for piece in pieces:
        guaranteed.extend(_hard_split(piece, MAX_CHUNK_TOKENS))
    return guaranteed


def split_file(path: Path, dry_run: bool = False) -> tuple[int, int, int]:
    """Returns (chunks_before, chunks_after, oversized_split)."""
    payload = json.loads(path.read_text(encoding="utf-8"))
    chunks = payload.get("chunks", [])

    out: list[dict] = []
    split_count = 0
    for chunk in chunks:
        text = chunk["text"]
        pieces = split_text(text)
        if len(pieces) == 1:
            out.append({**chunk, "token_count": _count_tokens(text)})
            continue
        split_count += 1
        for part_index, piece in enumerate(pieces, start=1):
            out.append(
                {
                    **chunk,
                    "text": piece,
                    "token_count": _count_tokens(piece),
                    # Provenance: which original chunk this came from, and where in it.
                    # Without this a re-chunk is untraceable and qrels cannot be remapped.
                    "split_from_chunk_index": chunk.get("chunk_index"),
                    "split_part": part_index,
                    "split_parts_total": len(pieces),
                }
            )

    for index, chunk in enumerate(out, start=1):
        chunk["chunk_index"] = index

    if not dry_run:
        payload["chunks"] = out
        payload["chunk_count"] = len(out)
        payload["max_chunk_tokens"] = MAX_CHUNK_TOKENS
        payload["overlap_tokens"] = OVERLAP_TOKENS
        path.write_text(
            json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8"
        )

    return len(chunks), len(out), split_count


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dir", type=Path, default=_ROOT / "data" / "neural_chunks")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    files = sorted(args.dir.glob("*.json"))
    if not files:
        raise SystemExit(f"No chunk JSON found in {args.dir}")

    before = after = split = 0
    for path in files:
        b, a, s = split_file(path, dry_run=args.dry_run)
        before += b
        after += a
        split += s
        if s:
            print(f"[SPLIT] {path.name}: {b} → {a} chunks ({s} oversized)")

    verb = "would split" if args.dry_run else "split"
    print(f"\n{verb} {split} oversized chunks; corpus {before} → {after} chunks")
    print(f"ceiling {MAX_CHUNK_TOKENS} tokens, overlap {OVERLAP_TOKENS}")
    if args.dry_run:
        print("\n(dry run — nothing written)")
    else:
        print("\nChunk IDs have shifted. Rebuild the index and remap the golden set:")
        print("  python -m eval.build_indexes")
        print("  python -m tools.remap_qrels --apply")


if __name__ == "__main__":
    main()
