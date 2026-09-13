#!/usr/bin/env python3
"""Measure how many GENERATION-model tokens one whitespace word costs, per shipped model.

`MedicalChatOrchestrator.estimateTokens` budgets the prompt as
`whitespace words x wordsToTokensRatio`. That budget exists to bound prefill on the
on-device chat model, so the ratio has to be measured with the tokenizers of the models
the app actually ships (`App/Backend/Configs/ModelCatalog.swift`) -- not with the retrieval
embedder's WordPiece vocabulary, which splits text very differently.

For every model it reports, over the whole chunk corpus:

  content   -- tokens(chunk text) / words(chunk text)
  formatted -- tokens("[section]\\n" + chunk text) / words(chunk text): what a packed chunk
               really costs in the prompt, label included, against the words the budget counts

as an aggregate (sum of tokens / sum of words, which is what a budget over many chunks
experiences), a median and a p90 per chunk. With `--vi` it does the same for Vietnamese
text, which the history budget meters on Vietnamese conversations.

The per-model value it recommends for `ModelCatalog.wordsToTokensRatio` is the ceiling over
both languages -- max(formatted EN aggregate, VI aggregate), rounded up to 0.05 -- so the
budget is never overshot on that model whichever language the history is in.

Only `tokenizer.json` is downloaded per model -- no weights.

    python -m tools.measure_token_ratio
    git show final/answer-quality:Pipeline/eval/data/queries_vi.jsonl > /tmp/queries_vi.jsonl
    git show final/answer-quality:Pipeline/eval/data/answer_quality/reference_answers.md > /tmp/ref.md
    python -m tools.measure_token_ratio --vi /tmp/queries_vi.jsonl /tmp/ref.md --out ../Docs/audits/token-ratio.json
"""

from __future__ import annotations

import argparse
import json
import math
import re
import statistics
from pathlib import Path

_ROOT = Path(__file__).resolve().parent.parent
_CATALOG = _ROOT.parent / "App" / "Backend" / "Configs" / "ModelCatalog.swift"

# Letters that only occur in Vietnamese, used to pick Vietnamese paragraphs out of Markdown.
_VI_MARKS = re.compile(
    r"[ăâđêôơưàáạảãằắặẳẵầấậẩẫèéẹẻẽềếệểễìíịỉĩòóọỏõồốộổỗờớợởỡùúụủũừứựửữỳýỵỷỹ]",
    re.IGNORECASE,
)


def catalog_repos(path: Path = _CATALOG) -> list[str]:
    """Repo ids parsed from ModelCatalog.swift, so this cannot drift from what ships."""
    source = path.read_text(encoding="utf-8")
    return re.findall(r'^\s*case\s+\w+\s*=\s*"([^"]+)"', source, flags=re.MULTILINE)


def words(text: str) -> int:
    """Mirrors `text.split { $0.isWhitespace }.count` in MedicalChatOrchestrator."""
    return len(text.split())


def formatted(section: str, text: str) -> str:
    """Mirrors `formatContextChunks`: one label line per chunk."""
    label = section if section else "General"
    return f"[{label}]\n{text}"


def load_corpus(chunks_dir: Path) -> list[tuple[str, str]]:
    rows: list[tuple[str, str]] = []
    for path in sorted(chunks_dir.glob("*.json")):
        payload = json.loads(path.read_text(encoding="utf-8"))
        for chunk in payload.get("chunks", []):
            text = chunk.get("text", "")
            if words(text):
                rows.append((chunk.get("section") or "", text))
    return rows


def load_vi(path: Path) -> list[str]:
    """Vietnamese text from a JSONL file (question/answer/text fields) or a Markdown file
    (every paragraph carrying Vietnamese letters, e.g. the answer-quality reference answers)."""
    raw = path.read_text(encoding="utf-8")
    texts: list[str] = []
    if path.suffix == ".md":
        for block in re.split(r"\n\s*\n", raw):
            block = re.sub(r"^\s*(#+|\*\*[^*]+\*\*:?)\s*", "", block.strip())
            if _VI_MARKS.search(block):
                texts.append(block)
    else:
        for line in raw.splitlines():
            if not line.strip():
                continue
            row = json.loads(line)
            texts.extend(row[k] for k in ("question", "answer", "text") if row.get(k))
    return [t for t in texts if words(t)]


def ratios(tokenizer, samples: list[tuple[str, str]]) -> dict:
    """samples: (text_to_tokenize, text_whose_words_are_counted)."""
    total_tokens = total_words = 0
    per_item: list[float] = []
    for to_tokenize, counted in samples:
        n_tokens = len(tokenizer.encode(to_tokenize, add_special_tokens=False).ids)
        n_words = words(counted)
        total_tokens += n_tokens
        total_words += n_words
        per_item.append(n_tokens / n_words)
    ordered = sorted(per_item)
    return {
        "aggregate": round(total_tokens / total_words, 4),
        "median": round(statistics.median(per_item), 4),
        "p90": round(ordered[int(0.9 * (len(ordered) - 1))], 4),
        "items": len(per_item),
        "words": total_words,
    }


def round_up(value: float, step: float = 0.05) -> float:
    return round(math.ceil(value / step - 1e-9) * step, 2)


def recommend(row: dict) -> float:
    ceiling = row["formatted"]["aggregate"]
    if "vietnamese" in row:
        ceiling = max(ceiling, row["vietnamese"]["aggregate"])
    return round_up(ceiling)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--chunks", type=Path, default=_ROOT / "data" / "neural_chunks")
    parser.add_argument(
        "--vi",
        type=Path,
        nargs="*",
        default=[],
        help="Vietnamese JSONL and/or Markdown files",
    )
    parser.add_argument(
        "--models", nargs="+", default=None, help="default: every ModelCatalog repo"
    )
    parser.add_argument("--out", type=Path, default=None)
    args = parser.parse_args()

    from huggingface_hub import hf_hub_download
    from tokenizers import Tokenizer

    corpus = load_corpus(args.chunks)
    vi = [text for path in args.vi for text in load_vi(path)]
    models = args.models or catalog_repos()
    print(
        f"corpus chunks: {len(corpus)} | vi texts: {len(vi)} | models: {len(models)}\n"
    )

    results = []
    for repo in models:
        tokenizer = Tokenizer.from_file(hf_hub_download(repo, "tokenizer.json"))
        row = {
            "model": repo,
            "content": ratios(tokenizer, [(t, t) for _, t in corpus]),
            "formatted": ratios(tokenizer, [(formatted(s, t), t) for s, t in corpus]),
        }
        if vi:
            row["vietnamese"] = ratios(tokenizer, [(t, t) for t in vi])
        row["recommended_ratio"] = recommend(row)
        results.append(row)
        line = (
            f"{repo:<46} EN formatted {row['formatted']['aggregate']:.3f} "
            f"(median {row['formatted']['median']:.3f}, p90 {row['formatted']['p90']:.3f})"
        )
        if vi:
            line += f"  VI {row['vietnamese']['aggregate']:.3f}"
        print(f"{line}  -> {row['recommended_ratio']:.2f}")

    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(
            json.dumps(
                {
                    "basis": "per model: max(aggregate formatted EN, aggregate VI) tokens/word, rounded up to 0.05",
                    "corpus_chunks": len(corpus),
                    "vietnamese_texts": len(vi),
                    "results": results,
                },
                indent=2,
                ensure_ascii=False,
            ),
            encoding="utf-8",
        )
        print(f"\nWrote {args.out}")


if __name__ == "__main__":
    main()
