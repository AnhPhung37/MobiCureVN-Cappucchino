"""Tests for the LoRA distillation dataset filters, splits and commands (no MLX needed).

Run from Pipeline/:
    python -m unittest eval.tests.test_distill_dataset
"""

from __future__ import annotations

import argparse
import unittest

from distill import build_distill_dataset as distill
from distill import run_distill


def _row(answer: str, vietnamese: bool = False, question: str = "What about stoma care?") -> dict:
    language = "Respond ONLY in Vietnamese (tiếng Việt)." if vietnamese else "Respond ONLY in English."
    return {
        "messages": [
            {"role": "system", "content": f"LANGUAGE: {language}\n\nPERSONA"},
            {"role": "user", "content": question},
            {"role": "assistant", "content": answer},
        ]
    }


class FilterTests(unittest.TestCase):
    def test_usable_answers_in_both_languages(self):
        self.assertIsNone(distill.rejection_reason(_row("Keep the skin around the stoma clean [1].")))
        self.assertIsNone(
            distill.rejection_reason(_row("Hãy giữ vùng da quanh lỗ mở thông sạch sẽ và khô ráo mỗi ngày.", True))
        )

    def test_wrong_language_is_rejected_both_ways(self):
        self.assertEqual(distill.rejection_reason(_row("Keep the skin clean and dry.", True)), "wrong_language")
        self.assertEqual(
            distill.rejection_reason(_row("Hãy giữ vùng da sạch sẽ và khô ráo mỗi ngày nhé.")), "wrong_language"
        )

    def test_empty_thinking_and_overlong_answers_are_rejected(self):
        self.assertEqual(distill.rejection_reason(_row("   ")), "no_answer")
        no_answer = _row("x")
        no_answer["messages"].pop()
        self.assertEqual(distill.rejection_reason(no_answer), "no_answer")
        self.assertEqual(distill.rejection_reason(_row("<think>hm</think> Fine.")), "thinking_left_in")
        # 512 tokens / 1.75 tokens per word = 292 words.
        self.assertIsNone(distill.rejection_reason(_row("word " * 292)))
        self.assertEqual(distill.rejection_reason(_row("word " * 293)), "over_answer_budget")

    def test_filter_counts_reasons(self):
        kept, rejected = distill.filter_records([_row("ok"), _row(""), _row("Xin chào bạn nhé", False)])
        self.assertEqual(len(kept), 1)
        self.assertEqual(rejected, {"no_answer": 1, "wrong_language": 1})


class SplitTests(unittest.TestCase):
    def test_split_is_a_stable_function_of_the_question(self):
        questions = [f"Question number {i}?" for i in range(400)]
        first = [distill.split_of(q) for q in questions]
        self.assertEqual(first, [distill.split_of(q) for q in questions])
        self.assertEqual(distill.split_of("Question Number 7"), distill.split_of("question number 7?"))
        counts = {name: first.count(name) for name in ("train", "valid", "test")}
        self.assertGreater(counts["train"], 320)
        self.assertGreater(counts["valid"], 5)
        self.assertGreater(counts["test"], 5)

    def test_split_records_routes_by_user_turn(self):
        rows = [_row("a", question=f"Q{i}?") for i in range(50)]
        splits = distill.split_records(rows)
        self.assertEqual(sum(len(v) for v in splits.values()), 50)
        for name, subset in splits.items():
            self.assertTrue(all(distill.split_of(r["messages"][1]["content"]) == name for r in subset))


class CommandTests(unittest.TestCase):
    def test_train_uses_the_masked_long_sequence_config(self):
        args = argparse.Namespace(student="Qwen/Qwen2.5-3B-Instruct", data="d", adapters="a", iters=None)
        command = run_distill.train_command(args)
        self.assertEqual(command[1:3], ["-m", "mlx_lm.lora"])
        config = run_distill.CONFIG.read_text()
        for line in ("mask_prompt: true", "max_seq_length: 4096", "fine_tune_type: lora", "train: true"):
            self.assertIn(line, config)

    def test_full_precision_students_are_quantized_to_the_catalog_layout(self):
        args = argparse.Namespace(student="s", adapters="a", out="o", student_is_quantized=False)
        fuse, convert = run_distill.fuse_commands(args)
        self.assertEqual(fuse[1:3], ["-m", "mlx_lm.fuse"])
        self.assertEqual(convert[convert.index("--q-bits") + 1], "4")
        self.assertEqual(convert[convert.index("--q-group-size") + 1], "64")
        quantized = run_distill.fuse_commands(argparse.Namespace(student="s", adapters="a", out="o", student_is_quantized=True))
        self.assertEqual(len(quantized), 1)


if __name__ == "__main__":
    unittest.main()
