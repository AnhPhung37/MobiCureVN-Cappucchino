"""Build the calibration set for DWQ (distilled weight quantization) of the chat model.

`mlx_lm.dwq` quantizes a model, then tunes the quantization scales and biases so the quantized
student's next-token distribution matches the full-precision teacher's over a calibration set.
Its default set (allenai/tulu-3-sft-mixture) is generic chat. What the app feeds the model is
different: a system prompt of persona, safety constraints and ~1,700 words of retrieved
colorectal-care passages, answered in English or Vietnamese. Calibrating on that shape spends
the student's limited precision where the app needs it.

Each record is one app-shaped turn in mlx-lm's chat format, {"messages": [...]}:

  system     the orchestrator's stable prefix, read from MedicalChatOrchestrator.swift so it
             cannot drift (language directive, invariant prompt, Vietnamese context note),
             then the volatile suffix with retrieved chunks formatted as `formatContextChunks`
             does ("[section]\\ntext", a blank line between chunks)
  user       an English question — ChatService translates Vietnamese before the orchestrator
  assistant  optional: the teacher's own answer from an OpenAI-compatible endpoint
             (`mlx_lm.server --model <teacher>`), so answer positions are calibrated too

Questions come from the corpus's section headings, never from the golden set: calibrating on
the evaluation questions would flatter the quantized model's answer-quality scores.
`--extra-questions` adds your own; any that match a golden question are dropped.

Approximations, stated so this is not mistaken for an exact prompt mirror: sources are listed
by document id, the confidence line is fixed, and chunks are packed whole to the word budget
instead of head-truncating the last one. They move a few tokens per prompt, not its shape.

Run from Pipeline/ after `python -m eval.build_indexes`:
    python -m quant.build_dwq_calibration --out quant/data/qwen3_5_4b
    python -m quant.build_dwq_calibration --out quant/data/qwen3_5_4b \\
        --teacher-base-url http://127.0.0.1:8080 --teacher-model Qwen/Qwen3.5-4B

Output: <out>/train.jsonl, plus <out>/README.md carrying the build manifest (a README is the one
extra file `datasets.load_dataset(<out>)` does not try to read as data).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import random
import re
import sys
from pathlib import Path
from typing import Callable

_PIPELINE = Path(__file__).resolve().parent.parent
_REPO = _PIPELINE.parent
ORCHESTRATOR = _REPO / "App" / "Backend" / "Services" / "GuardRail" / "MedicalChatOrchestrator.swift"

# App defaults (App/Resources/InferenceTuning.json) at Qwen 3.5's measured ratio.
RETRIEVAL_TOP_K = 10
CONTEXT_TOKEN_BUDGET = 3000
WORDS_TO_TOKENS = 1.75
CONFIDENCE_LINE = "Confidence Score: 70%"

QUESTION_TEMPLATES = (
    "What should I know about {topic}?",
    "Can you explain {topic} in simple terms?",
    "Is there anything I should watch out for with {topic}?",
)

Search = Callable[[str, int], list[tuple[str, str]]]
Teacher = Callable[[list[dict]], str]


# ── Swift source ─────────────────────────────────────────────────────────────


def swift_multiline_literal(source: str, marker: str) -> str:
    """The first triple-quoted Swift string after `marker`, as Swift evaluates it.

    Indentation equal to the closing delimiter's is stripped, a trailing backslash joins the
    next line, and an interpolation is refused: the value would not be a constant.
    """
    start = source.find(marker)
    if start < 0:
        raise ValueError(f"{marker!r} not found in the Swift source")
    opening = source.find('"""', start)
    body_start = source.find("\n", opening) + 1
    closing = re.compile(r'^([ \t]*)"""', re.MULTILINE).search(source, body_start)
    if opening < 0 or closing is None:
        raise ValueError(f"no complete multi-line literal after {marker!r}")
    indent = closing.group(1)

    lines: list[str] = []
    for line in source[body_start : closing.start()].split("\n")[:-1]:
        if not line.strip():
            lines.append("")
        elif line.startswith(indent):
            lines.append(line[len(indent) :])
        else:
            raise ValueError(f"line under-indented in literal after {marker!r}: {line!r}")

    text = ""
    for index, line in enumerate(lines):
        if line.endswith("\\") and not line.endswith("\\\\"):
            text += line[:-1]
        else:
            text += line + ("\n" if index < len(lines) - 1 else "")
    if "\\(" in text:
        raise ValueError(f"literal after {marker!r} interpolates; it is not a constant")
    return text.replace('\\"', '"').replace("\\\\", "\\")


def app_prompt_pieces(orchestrator: Path = ORCHESTRATOR) -> dict[str, str]:
    source = orchestrator.read_text(encoding="utf-8")
    language = re.search(
        r'let languageInstruction = answersInVietnamese\s*\?\s*"((?:[^"\\]|\\.)*)"\s*:\s*"((?:[^"\\]|\\.)*)"',
        source,
    )
    if language is None:
        raise ValueError("languageInstruction not found in MedicalChatOrchestrator.swift")
    return {
        "invariant": swift_multiline_literal(source, "static let invariantSystemPrompt ="),
        "language_vi": language.group(1),
        "language_en": language.group(2),
        "context_note_vi": swift_multiline_literal(source, "let contextLanguageNote = answersInVietnamese ?"),
    }


# ── Prompt ───────────────────────────────────────────────────────────────────


def words(text: str) -> int:
    return len(text.split())


def format_chunk(section: str, text: str) -> str:
    """Mirrors MedicalChatOrchestrator.formatContextChunks for one chunk."""
    return f"[{section or 'General'}]\n{text}"


def pack(rows: list[tuple[str, str, str]], word_budget: int) -> list[tuple[str, str, str]]:
    """(chunk_id, section, text) rows in retrieval order, whole, while they fit the budget."""
    packed: list[tuple[str, str, str]] = []
    used = 0
    for row in rows:
        cost = words(format_chunk(row[1], row[2]))
        if used + cost > word_budget:
            break
        packed.append(row)
        used += cost
    return packed


def doc_id_of(chunk_id: str) -> str:
    return chunk_id.rsplit("_c", 1)[0]


def system_prompt(pieces: dict[str, str], vietnamese: bool, packed: list[tuple[str, str, str]]) -> str:
    language = pieces["language_vi"] if vietnamese else pieces["language_en"]
    stable = f"LANGUAGE: {language}\n\n{pieces['invariant']}" + (pieces["context_note_vi"] if vietnamese else "")
    context = "\n\n".join(format_chunk(section, text) for _, section, text in packed)
    doc_ids = list(dict.fromkeys(doc_id_of(chunk_id) for chunk_id, _, _ in packed))
    sources = "\n".join(f"[{i}] {doc_id}" for i, doc_id in enumerate(doc_ids, start=1))
    volatile = (
        f"\n\nRetrieved Medical Context:\n{context}\n\nSources:\n{sources}\n\n"
        f"{CONFIDENCE_LINE}\n\nREMINDER — {language}"
    )
    return stable + volatile


# ── Questions ────────────────────────────────────────────────────────────────


def normalize_question(text: str) -> str:
    return re.sub(r"\s+", " ", text.lower()).strip(" ?.!")


def clean_topic(section: str | None) -> str | None:
    if not section:
        return None
    topic = re.sub(r"\s+", " ", re.sub(r"^[#*\s\d.:\-–—]+|[#*\s:]+$", "", section)).strip()
    if not 3 <= len(topic) <= 80 or not re.search(r"[A-Za-z]{3}", topic):
        return None
    if not topic[:2].isupper():
        topic = topic[0].lower() + topic[1:]
    return topic


def section_questions(sections: list[str | None], golden: set[str], seed: int, limit: int) -> tuple[list[str], int]:
    """One templated question per distinct heading; returns (questions, dropped as golden)."""
    rng = random.Random(seed)
    topics = list(dict.fromkeys(t for t in map(clean_topic, sections) if t))
    questions: list[str] = []
    dropped = 0
    for topic in topics:
        question = rng.choice(QUESTION_TEMPLATES).format(topic=topic)
        if normalize_question(question) in golden:
            dropped += 1
            continue
        questions.append(question)
    rng.shuffle(questions)
    return questions[:limit], dropped


# ── Records ──────────────────────────────────────────────────────────────────


def strip_thinking(answer: str) -> str:
    return re.sub(r"<think>.*?</think>", "", answer, flags=re.DOTALL).strip()


def build_records(
    questions: list[str],
    search: Search,
    sections: dict[str, str],
    pieces: dict[str, str],
    *,
    vietnamese_fraction: float,
    seed: int,
    teacher: Teacher | None = None,
    word_budget: int = int(CONTEXT_TOKEN_BUDGET / WORDS_TO_TOKENS),
) -> tuple[list[dict], dict]:
    rng = random.Random(seed)
    records: list[dict] = []
    stats = {"english": 0, "vietnamese": 0, "skipped_no_context": 0, "with_teacher_answer": 0}
    for question in questions:
        rows = [(cid, sections.get(cid, ""), text) for cid, text in search(question, RETRIEVAL_TOP_K)]
        packed = pack(rows, word_budget)
        if not packed:
            stats["skipped_no_context"] += 1
            continue
        vietnamese = rng.random() < vietnamese_fraction
        messages = [
            {"role": "system", "content": system_prompt(pieces, vietnamese, packed)},
            {"role": "user", "content": question},
        ]
        if teacher is not None:
            answer = strip_thinking(teacher(messages))
            if answer:
                messages.append({"role": "assistant", "content": answer})
                stats["with_teacher_answer"] += 1
        stats["vietnamese" if vietnamese else "english"] += 1
        records.append({"messages": messages})
    return records, stats


def openai_compatible_teacher(base_url: str, model: str, timeout_s: int = 600) -> Teacher:
    """Answers with the app's generation settings (InferenceTuning: 512 tokens, T 0.3, top-p 0.85)."""
    import httpx

    def answer(messages: list[dict]) -> str:
        response = httpx.post(
            f"{base_url.rstrip('/')}/v1/chat/completions",
            json={"model": model, "messages": messages, "max_tokens": 512, "temperature": 0.3, "top_p": 0.85},
            timeout=timeout_s,
        )
        response.raise_for_status()
        return response.json()["choices"][0]["message"]["content"]

    return answer


def _load_jsonl(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--config", type=Path, default=_PIPELINE / "eval" / "experiment_config.json")
    parser.add_argument("--max-questions", type=int, default=1024)
    parser.add_argument("--vietnamese-fraction", type=float, default=0.3)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--extra-questions", type=Path, default=None, help='JSONL with a "question" field')
    parser.add_argument("--teacher-base-url", default=None)
    parser.add_argument("--teacher-model", default=None)
    args = parser.parse_args()
    if bool(args.teacher_base_url) != bool(args.teacher_model):
        parser.error("--teacher-base-url and --teacher-model go together")

    sys.path.insert(0, str(_PIPELINE))
    from eval.index_builder import load_all_chunks
    from eval.retriever import Embedder, HybridRetriever

    cfg = json.loads(args.config.read_text(encoding="utf-8"))
    eval_dir = args.config.parent
    app = next(e for e in cfg["experiments"] if e.get("represents_app"))

    golden_path = (eval_dir / cfg["evaluation"]["queries_path"]).resolve()
    golden_rows = _load_jsonl(golden_path)
    vi_path = golden_path.with_name("queries_vi.jsonl")
    if vi_path.exists():
        golden_rows += _load_jsonl(vi_path)
    golden = {normalize_question(r[key]) for r in golden_rows for key in ("question", "en_equivalent") if r.get(key)}

    chunks = load_all_chunks((eval_dir / app["enriched_output_dir"]).resolve())
    sections = {c["chunk_id"]: c.get("section") or "" for c in chunks}
    questions, dropped = section_questions([c.get("section") for c in chunks], golden, args.seed, args.max_questions)
    if args.extra_questions:
        extra = [r["question"] for r in _load_jsonl(args.extra_questions)]
        kept = [q for q in extra if normalize_question(q) not in golden]
        dropped += len(extra) - len(kept)
        questions = kept + questions

    retriever = HybridRetriever(
        (eval_dir / app["index_db_path"]).resolve(),
        Embedder(cfg["embed"]["model_name"], batch_size=cfg["embed"]["batch_size"]),
        always_fuse=True,
        drop_stopwords=True,
    )
    teacher = openai_compatible_teacher(args.teacher_base_url, args.teacher_model) if args.teacher_base_url else None
    records, stats = build_records(
        questions,
        lambda q, k: [(c.chunk_id, c.text) for c in retriever.search(q, k)],
        sections,
        app_prompt_pieces(),
        vietnamese_fraction=args.vietnamese_fraction,
        seed=args.seed,
        teacher=teacher,
    )

    args.out.mkdir(parents=True, exist_ok=True)
    train = args.out / "train.jsonl"
    train.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in records), encoding="utf-8")
    manifest = {
        "records": len(records),
        **stats,
        "dropped_as_golden": dropped,
        "teacher_model": args.teacher_model,
        "seed": args.seed,
        "train_sha256": hashlib.sha256(train.read_bytes()).hexdigest(),
        "orchestrator_sha256": hashlib.sha256(ORCHESTRATOR.read_bytes()).hexdigest(),
    }
    (args.out / "README.md").write_text(
        "# DWQ calibration set\n\nBuilt by `python -m quant.build_dwq_calibration`.\n\n```json\n"
        + json.dumps(manifest, indent=2)
        + "\n```\n",
        encoding="utf-8",
    )
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
