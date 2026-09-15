"""Build a LoRA distillation set: a larger teacher answering the app's own prompts.

The on-device chat model is small, and the answer-quality rubric shows where it falls short of a
larger model given the same retrieved context. Distillation fine-tunes the small model on the
larger model's answers to app-shaped turns, so it learns this task's register — grounded in the
passages, cited, conditional, warm, in the requested language — rather than general chat.

Rows are built exactly like the DWQ calibration set (`quant.build_dwq_calibration`, which this
branch reuses rather than copies): the orchestrator's stable prefix parsed from Swift, hybrid-
retrieved context packed to the app budget, section-heading questions that exclude the golden
set. The difference is that a teacher answer is required and then filtered:

  - empty answers, and answers still carrying `<think>`, are dropped;
  - an answer in the wrong language for its directive is dropped (Vietnamese-letter word share
    >= 0.25 for a Vietnamese directive, <= 0.02 for an English one) — training on those would
    teach the drift the app's guardrails exist to catch;
  - an answer over the app's 512-token answer budget (at 1.75 tokens/word) is dropped, because
    the student is cut at `maxTokens` on the device and would learn to lose its disclaimer.

Rows are split 90/5/5 into train/valid/test by a hash of the question, so re-running with more
questions never moves an existing question between splits.

Run from Pipeline/ on the machine serving the teacher:
    mlx_lm.server --model <teacher> --port 8080 &
    python -m distill.build_distill_dataset --out distill/data/qwen2_5_3b \\
        --teacher-base-url http://127.0.0.1:8080 --teacher-model <teacher>
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

from quant import build_dwq_calibration as calib

ANSWER_TOKEN_BUDGET = 512  # InferenceTuning generation.maxTokens
VIETNAMESE_MIN_SHARE = 0.25
ENGLISH_MAX_SHARE = 0.02

# Letters only Vietnamese uses among the app's two languages (same set as tools/measure_token_ratio).
_VI_LETTERS = re.compile(
    r"[ăâđêôơưàáạảãằắặẳẵầấậẩẫèéẹẻẽềếệểễìíịỉĩòóọỏõồốộổỗờớợởỡùúụủũừứựửữỳýỵỷỹ]", re.IGNORECASE
)


def vietnamese_word_share(text: str) -> float:
    tokens = text.split()
    return sum(1 for t in tokens if _VI_LETTERS.search(t)) / len(tokens) if tokens else 0.0


def rejection_reason(record: dict) -> str | None:
    """Why a teacher row must not be trained on, or None when it is usable."""
    messages = record["messages"]
    if len(messages) < 3 or messages[-1]["role"] != "assistant" or not messages[-1]["content"].strip():
        return "no_answer"
    answer = messages[-1]["content"]
    if "<think>" in answer or "</think>" in answer:
        return "thinking_left_in"
    share = vietnamese_word_share(answer)
    wants_vietnamese = messages[0]["content"].startswith("LANGUAGE: Respond ONLY in Vietnamese")
    if wants_vietnamese and share < VIETNAMESE_MIN_SHARE:
        return "wrong_language"
    if not wants_vietnamese and share > ENGLISH_MAX_SHARE:
        return "wrong_language"
    if calib.words(answer) * calib.WORDS_TO_TOKENS > ANSWER_TOKEN_BUDGET:
        return "over_answer_budget"
    return None


def split_of(question: str) -> str:
    bucket = int(hashlib.sha256(calib.normalize_question(question).encode()).hexdigest(), 16) % 20
    return "test" if bucket == 0 else "valid" if bucket == 1 else "train"


def split_records(records: list[dict]) -> dict[str, list[dict]]:
    splits: dict[str, list[dict]] = {"train": [], "valid": [], "test": []}
    for record in records:
        splits[split_of(record["messages"][1]["content"])].append(record)
    return splits


def filter_records(records: list[dict]) -> tuple[list[dict], dict[str, int]]:
    kept: list[dict] = []
    rejected: dict[str, int] = {}
    for record in records:
        reason = rejection_reason(record)
        if reason is None:
            kept.append(record)
        else:
            rejected[reason] = rejected.get(reason, 0) + 1
    return kept, rejected


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--teacher-base-url", required=True)
    parser.add_argument("--teacher-model", required=True)
    parser.add_argument("--config", type=Path, default=calib._PIPELINE / "eval" / "experiment_config.json")
    parser.add_argument("--max-questions", type=int, default=2000)
    parser.add_argument("--vietnamese-fraction", type=float, default=0.5)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--extra-questions", type=Path, default=None)
    args = parser.parse_args()

    # Reuse the calibration builder's CLI path end to end, then filter and split its rows.
    calibration_out = args.out / "_unfiltered"
    sys.argv = [
        "build_dwq_calibration",
        "--out", str(calibration_out),
        "--config", str(args.config),
        "--max-questions", str(args.max_questions),
        "--vietnamese-fraction", str(args.vietnamese_fraction),
        "--seed", str(args.seed),
        "--teacher-base-url", args.teacher_base_url,
        "--teacher-model", args.teacher_model,
    ] + (["--extra-questions", str(args.extra_questions)] if args.extra_questions else [])
    calib.main()

    rows = [json.loads(line) for line in (calibration_out / "train.jsonl").read_text(encoding="utf-8").splitlines() if line]
    kept, rejected = filter_records(rows)
    splits = split_records(kept)
    if not splits["valid"]:
        raise SystemExit("no validation rows after filtering; build more questions")
    for name, subset in splits.items():
        (args.out / f"{name}.jsonl").write_text(
            "".join(json.dumps(r, ensure_ascii=False) + "\n" for r in subset), encoding="utf-8"
        )
    manifest = {
        "teacher_model": args.teacher_model,
        "teacher_rows": len(rows),
        "kept": len(kept),
        "rejected": rejected,
        "splits": {name: len(subset) for name, subset in splits.items()},
        "train_sha256": hashlib.sha256((args.out / "train.jsonl").read_bytes()).hexdigest(),
    }
    (args.out / "README.md").write_text(
        "# LoRA distillation set\n\nBuilt by `python -m distill.build_distill_dataset`.\n\n```json\n"
        + json.dumps(manifest, indent=2)
        + "\n```\n",
        encoding="utf-8",
    )
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
