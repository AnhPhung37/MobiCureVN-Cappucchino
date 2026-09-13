"""Tests for the DWQ calibration builder and runner (no MLX needed).

Run from Pipeline/:
    python -m unittest eval.tests.test_dwq_calibration
"""

from __future__ import annotations

import argparse
import unittest

from quant import build_dwq_calibration as calib
from quant import run_dwq


class SwiftLiteralTests(unittest.TestCase):
    def test_indentation_continuation_and_escapes(self):
        source = 'x\n    let v = """\n    first \\\n    same line\n\n      indented \\"quoted\\"\n    """\n'
        self.assertEqual(calib.swift_multiline_literal(source, "let v ="), 'first same line\n\n  indented "quoted"')

    def test_an_interpolating_literal_is_refused(self):
        with self.assertRaises(ValueError):
            calib.swift_multiline_literal('let v = """\n  a \\(b)\n  """\n', "let v =")

    def test_the_orchestrator_prompt_is_read_verbatim(self):
        pieces = calib.app_prompt_pieces()
        self.assertTrue(pieces["invariant"].startswith("You are a warm, supportive medical information assistant"))
        self.assertIn("\nCONSTRAINTS:\n", pieces["invariant"])
        self.assertFalse(any(line.startswith("        ") for line in pieces["invariant"].splitlines()))
        self.assertTrue(pieces["language_vi"].startswith("Respond ONLY in Vietnamese"))
        self.assertTrue(pieces["language_en"].startswith("Respond ONLY in English"))
        self.assertTrue(pieces["context_note_vi"].startswith("\n- The Retrieved Medical Context below is written in ENGLISH."))


class PromptShapeTests(unittest.TestCase):
    PIECES = {"invariant": "PERSONA", "language_vi": "VI!", "language_en": "EN!", "context_note_vi": "\n- NOTE"}

    def test_english_turn(self):
        packed = [("DOC_A_c001", "", "alpha"), ("DOC_A_c002", "Diet", "beta"), ("DOC_B_c010", "Care", "gamma")]
        self.assertEqual(
            calib.system_prompt(self.PIECES, False, packed),
            "LANGUAGE: EN!\n\nPERSONA\n\nRetrieved Medical Context:\n[General]\nalpha\n\n[Diet]\nbeta\n\n[Care]\ngamma"
            "\n\nSources:\n[1] DOC_A\n[2] DOC_B\n\nConfidence Score: 70%\n\nREMINDER — EN!",
        )

    def test_vietnamese_turn_adds_the_context_note_to_the_stable_prefix(self):
        prompt = calib.system_prompt(self.PIECES, True, [("D_c001", "S", "t")])
        self.assertTrue(prompt.startswith("LANGUAGE: VI!\n\nPERSONA\n- NOTE\n\nRetrieved Medical Context:"))
        self.assertTrue(prompt.endswith("REMINDER — VI!"))

    def test_packing_keeps_whole_chunks_within_the_word_budget(self):
        rows = [("a", "S", "one two"), ("b", "S", "three four five"), ("c", "S", "six")]
        # "[S]\none two" = 3 words, then 4, then 2.
        self.assertEqual([r[0] for r in calib.pack(rows, 7)], ["a", "b"])
        self.assertEqual([r[0] for r in calib.pack(rows, 6)], ["a"])


class QuestionTests(unittest.TestCase):
    def test_headings_become_questions_and_golden_questions_are_dropped(self):
        golden = {calib.normalize_question("What should I know about diet after surgery?")}
        sections = ["## Diet after surgery", "Diet after surgery", "12", None, "Stoma care", "NHS guidance"]
        questions, dropped = calib.section_questions(sections, golden, seed=0, limit=10)
        self.assertLessEqual(len(questions) + dropped, 3, "one question per distinct heading")
        self.assertTrue(all("12" not in q for q in questions))
        self.assertIn("NHS guidance", " ".join(questions), "acronym-led topics keep their case")
        for q in questions:
            self.assertNotIn(calib.normalize_question(q), golden)

    def test_topic_cleaning(self):
        self.assertEqual(calib.clean_topic("### 3. Looking After Your Stoma:"), "looking After Your Stoma")
        self.assertIsNone(calib.clean_topic("—"))


class RecordTests(unittest.TestCase):
    PIECES = PromptShapeTests.PIECES

    def test_records_are_mlx_chat_rows_and_reproducible(self):
        def search(question, k):
            self.assertEqual(k, calib.RETRIEVAL_TOP_K)
            return [] if "empty" in question else [("DOC_c001", "chunk text")]

        def teacher(messages):
            return "<think>\nplan\n</think>\nAnswer."

        kwargs = dict(vietnamese_fraction=0.5, seed=7, teacher=teacher)
        questions = ["What about stomas?", "empty result?", "Diet?"]
        first, stats = calib.build_records(questions, search, {"DOC_c001": "Care"}, self.PIECES, **kwargs)
        second, _ = calib.build_records(questions, search, {"DOC_c001": "Care"}, self.PIECES, **kwargs)
        self.assertEqual(first, second)
        self.assertEqual(stats["skipped_no_context"], 1)
        self.assertEqual(stats["english"] + stats["vietnamese"], 2)
        for record in first:
            self.assertEqual([m["role"] for m in record["messages"]], ["system", "user", "assistant"])
            self.assertEqual(record["messages"][2]["content"], "Answer.")
            self.assertIn("[Care]\nchunk text", record["messages"][0]["content"])


class RunDwqTests(unittest.TestCase):
    def _args(self, **overrides):
        values = dict(
            teacher="Qwen/Qwen2.5-3B-Instruct", quantized_model=None, data="d", mlx_path="m", bits=4,
            group_size=64, max_seq_length=4096, batch_size=1, learning_rate=1e-6, seed=123, grad_checkpoint=True,
        )
        values.update(overrides)
        return argparse.Namespace(**values)

    def test_command_carries_app_sized_sequences(self):
        command = run_dwq.dwq_command(self._args(), 512)
        self.assertEqual(command[1:3], ["-m", "mlx_lm.dwq"])
        self.assertEqual(command[command.index("--max-seq-length") + 1], "4096")
        self.assertEqual(command[command.index("--num-samples") + 1], "512")
        self.assertIn("--grad-checkpoint", command)
        self.assertNotIn("--quantized-model", command)

    def test_sample_count_leaves_validation_rows(self):
        self.assertEqual(run_dwq.num_samples_for(100, None), 68)
        self.assertEqual(run_dwq.num_samples_for(5000, None), 2048)
        with self.assertRaises(SystemExit):
            run_dwq.num_samples_for(100, 90)
        with self.assertRaises(SystemExit):
            run_dwq.num_samples_for(40, None)


if __name__ == "__main__":
    unittest.main()
