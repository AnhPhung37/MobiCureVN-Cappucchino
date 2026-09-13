"""Stage 3b: split chunks that exceed the embedder's context window.

The retrieval embedder (`BAAI/bge-small-en-v1.5`) has a 512-token window. Anything past
that in a chunk is **silently never embedded** — the passage is only ever retrievable by its
opening. Measured on the shipped corpus: 17.7% of chunks exceed 512 tokens and the largest
is ~13,664. The same chunks break prompt packing downstream (Docs/BE/Context-Budget-Finding.md).

This stage works on the chunk JSON rather than the source Markdown, so it applies to an
existing corpus without re-running the neural chunker, and is independent of which chunker
produced the input. `run_pipeline.sh` runs it between `chunk` and `enrich`; it is idempotent.

Rules, each one a defect of the first version:

- **Pieces are slices of the original text.** Cuts are found with the tokenizer's offset
  mapping and made in the source string. The first version decoded token ids back to text,
  which through an uncased WordPiece vocabulary lower-cased every hard-split piece and
  re-spaced its punctuation ("nccn. org / disclosures") — text the answering model and the
  citation cards then read (249 pieces).
- **Cuts fall on whitespace**, preferring paragraph, then sentence boundaries. For BERT
  tokenization token counts are then additive across a cut, so the ceiling is exact rather
  than repaired afterwards.
- **An overlap is a tail, never a piece.** At most OVERLAP_TOKENS from the end of the previous
  piece, starting at a sentence boundary when one fits and at a word boundary otherwise, and it
  is never emitted on its own. The first version carried a whole over-long sentence forward and
  flushed it as a piece of its own (84 duplicated pieces).
- **Every chunk records `source_chunk_index`**, the chunk_index it had before splitting, so the
  golden set can be remapped exactly (`tools/remap_qrels.py --from-split-provenance`).

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

EMBED_MODEL = "BAAI/bge-small-en-v1.5"

# The embedder window is 512; [CLS] and [SEP] take two of those.
MAX_CHUNK_TOKENS = 480

# Carried from the end of one piece into the start of the next, so a fact straddling a cut
# survives whole in at least one piece.
OVERLAP_TOKENS = 48

# Below this a trailing piece cannot stand alone as a retrievable passage; it is folded into
# the previous piece when that stays under the ceiling.
MIN_PIECE_TOKENS = 40

_PARAGRAPH_RE = re.compile(r"\n\s*\n")
_SENTENCE_END_RE = re.compile(r"(?<=[.!?])\s+")

_tokenizer = None


def _tok():
    global _tokenizer
    if _tokenizer is None:
        from transformers import AutoTokenizer

        _tokenizer = AutoTokenizer.from_pretrained(EMBED_MODEL)
        # Counting long chunks is the point; silence the "longer than the model maximum" warning.
        _tokenizer.model_max_length = 10**9
    return _tokenizer


def count_tokens(text: str) -> int:
    return len(_tok()(text, add_special_tokens=False)["input_ids"])


def _offsets(text: str) -> list[tuple[int, int]]:
    return _tok()(text, add_special_tokens=False, return_offsets_mapping=True)["offset_mapping"]


def _hard_split(text: str, limit: int) -> list[str]:
    """Cut one over-long passage into pieces of at most `limit` tokens, at whitespace where the
    window has any, always slicing the original string."""
    pieces: list[str] = []
    rest = text.strip()
    while rest:
        if count_tokens(rest) <= limit:
            pieces.append(rest)
            break
        window_end = _offsets(rest)[limit - 1][1]
        cut = max(rest.rfind(" ", 0, window_end + 1), rest.rfind("\n", 0, window_end + 1))
        if cut <= 0:
            # One "word" longer than the window (an unbroken URL or table row): cut on the token
            # boundary instead, shrinking until the slice itself fits.
            cut = window_end
        piece = rest[:cut].strip()
        while piece and count_tokens(piece) > limit:
            piece = piece[: _offsets(piece)[limit - 1][1]].strip()
        if not piece:
            raise ValueError(f"cannot split {rest[:80]!r} under {limit} tokens")
        pieces.append(piece)
        rest = rest[len(piece) :].strip() if rest.startswith(piece) else rest[cut:].strip()
    return pieces


def _units(text: str) -> list[tuple[str, str]]:
    """The smallest spans a cut may fall between, each with the separator that preceded it in
    the source: paragraphs; sentences of an over-long paragraph; hard pieces of an over-long
    sentence."""
    units: list[tuple[str, str]] = []
    for para in _PARAGRAPH_RE.split(text):
        para = para.strip()
        if not para:
            continue
        separator = "\n\n"
        if count_tokens(para) <= MAX_CHUNK_TOKENS:
            units.append((para, separator))
            continue
        for sentence in _SENTENCE_END_RE.split(para):
            sentence = sentence.strip()
            if not sentence:
                continue
            for piece in _hard_split(sentence, MAX_CHUNK_TOKENS):
                units.append((piece, separator))
                separator = " "
    return units


def _join(units: list[tuple[str, str]]) -> str:
    text = ""
    for unit, separator in units:
        text = unit if not text else text + separator + unit
    return text


def overlap_tail(text: str, tokens: int = OVERLAP_TOKENS) -> str:
    """At most `tokens` tokens from the end of `text`: from a sentence start when a whole
    trailing sentence fits, otherwise from a word start. Empty when nothing shorter than the
    whole text fits — an overlap must never duplicate the entire previous piece."""
    if tokens <= 0 or not text:
        return ""
    starts = [0] + [m.end() for m in _SENTENCE_END_RE.finditer(text)]
    best = None
    for start in reversed(starts[1:]):
        if count_tokens(text[start:]) <= tokens:
            best = start
        else:
            break
    if best is not None:
        return text[best:].strip()
    offsets = _offsets(text)
    if len(offsets) <= tokens:
        return ""
    start = offsets[-tokens][0]
    if start > 0 and not text[start - 1].isspace():
        next_space = min((i for i in (text.find(" ", start), text.find("\n", start)) if i != -1), default=-1)
        if next_space == -1:
            return ""
        start = next_space
    tail = text[start:].strip()
    return tail if tail and count_tokens(tail) <= tokens else ""


def split_text(text: str) -> list[str]:
    """Split `text` into pieces of at most MAX_CHUNK_TOKENS tokens (see the module rules)."""
    if count_tokens(text) <= MAX_CHUNK_TOKENS:
        return [text]

    pieces: list[str] = []
    carry: tuple[str, int] | None = None  # overlap text and its token count
    new_units: list[tuple[str, str]] = []
    new_tokens = 0

    def flush() -> None:
        nonlocal carry, new_units, new_tokens
        body = _join(new_units)
        piece = body if carry is None else carry[0] + new_units[0][1] + body
        pieces.append(piece)
        tail = overlap_tail(piece)
        carry = (tail, count_tokens(tail)) if tail else None
        new_units, new_tokens = [], 0

    for unit, separator in _units(text):
        cost = count_tokens(unit)
        carried = carry[1] if carry else 0
        if new_units and carried + new_tokens + cost > MAX_CHUNK_TOKENS:
            flush()
            carried = carry[1] if carry else 0
        if not new_units and carry and carried + cost > MAX_CHUNK_TOKENS:
            carry, carried = None, 0  # this unit cannot share a piece with the overlap
        new_units.append((unit, separator))
        new_tokens += cost

    if new_units:
        body = _join(new_units)
        if pieces and new_tokens < MIN_PIECE_TOKENS and count_tokens(pieces[-1]) + new_tokens <= MAX_CHUNK_TOKENS:
            pieces[-1] = pieces[-1] + new_units[0][1] + body
        else:
            pieces.append(body if carry is None else carry[0] + new_units[0][1] + body)

    deduped: list[str] = []
    for piece in pieces:
        if not deduped or piece != deduped[-1]:
            deduped.append(piece)
    oversized = [count_tokens(p) for p in deduped if count_tokens(p) > MAX_CHUNK_TOKENS]
    if oversized:
        raise ValueError(f"split produced pieces over the ceiling: {oversized}")
    return deduped


def split_file(path: Path, dry_run: bool = False) -> tuple[int, int, int]:
    """Returns (chunks_before, chunks_after, oversized_split)."""
    payload = json.loads(path.read_text(encoding="utf-8"))
    chunks = payload.get("chunks", [])

    out: list[dict] = []
    split_count = 0
    for chunk in chunks:
        # Idempotent: a chunk that is already a split piece keeps the index of the chunk it
        # originally came from.
        source_index = chunk.get("source_chunk_index", chunk.get("chunk_index"))
        pieces = split_text(chunk["text"])
        if len(pieces) == 1:
            out.append({**chunk, "token_count": count_tokens(chunk["text"]), "source_chunk_index": source_index})
            continue
        split_count += 1
        for part_index, piece in enumerate(pieces, start=1):
            out.append(
                {
                    **chunk,
                    "text": piece,
                    "token_count": count_tokens(piece),
                    "source_chunk_index": source_index,
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
        path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")

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
    print(f"ceiling {MAX_CHUNK_TOKENS} tokens, overlap ≤ {OVERLAP_TOKENS}")
    if args.dry_run:
        print("\n(dry run — nothing written)")
    elif split:
        print("\nChunk IDs have shifted. Rebuild the indexes and remap the golden set:")
        print("  python -m tools.remap_qrels --from-split-provenance --apply")


if __name__ == "__main__":
    main()
