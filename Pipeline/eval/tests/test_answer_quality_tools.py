"""Tests for the manual answer-quality tooling.

The sheets and the scorer are the only thing standing between "we reviewed the
answers" and a number a panel can question, so the failure modes that matter are
the quiet ones: a sheet that scores nothing, raters who scored different
questions, and an unsafe answer averaged into invisibility.

    cd Pipeline && python -m unittest discover -s eval/tests -t .
"""

from __future__ import annotations

import csv
import io
import json
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

PIPELINE = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(PIPELINE))

from tools import make_answer_sheet as sheet_tool  # noqa: E402
from tools import score_answer_sheet as score_tool  # noqa: E402


def write_sheet(path: Path, rows: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(
            f,
            fieldnames=score_tool.DIMENSIONS + ["query_id", "language", "rater_notes"],
        )
        writer.writeheader()
        writer.writerows(rows)


def row(qid: str, language: str = "en", **scores) -> dict:
    base = {"query_id": qid, "language": language, "rater_notes": ""}
    for dim in score_tool.DIMENSIONS:
        base[dim] = str(scores.get(dim, 2))
    return base


class SampleSelectionTests(unittest.TestCase):
    def test_sample_is_deterministic(self):
        rows = [
            {"query_id": f"q{i:03d}", "question": "?", "language": "en"}
            for i in range(1, 60)
        ]
        first = [r["query_id"] for r in sheet_tool.stratify(rows, 10)]
        second = [r["query_id"] for r in sheet_tool.stratify(rows, 10)]
        self.assertEqual(first, second, "two raters must be given the same questions")

    def test_sample_covers_every_language_present(self):
        rows = [
            {"query_id": f"e{i}", "question": "?", "language": "en"} for i in range(40)
        ]
        rows += [
            {"query_id": f"v{i}", "question": "?", "language": "vi"} for i in range(12)
        ]
        sample = sheet_tool.stratify(rows, 30)
        langs = {r["language"] for r in sample}
        self.assertEqual(
            langs, {"en", "vi"}, "a monolingual sheet cannot certify criterion #4"
        )

    def test_sample_size_is_respected(self):
        rows = [
            {"query_id": f"q{i:03d}", "question": "?", "language": "en"}
            for i in range(1, 60)
        ]
        self.assertEqual(len(sheet_tool.stratify(rows, 17)), 17)

    def test_vietnamese_query_file_is_present_and_well_formed(self):
        path = PIPELINE / "eval" / "data" / "queries_vi.jsonl"
        self.assertTrue(path.exists(), "criterion #4 needs a Vietnamese query set")
        rows = [
            json.loads(line)
            for line in path.read_text(encoding="utf-8").splitlines()
            if line.strip()
        ]
        self.assertGreaterEqual(len(rows), 10)
        for r in rows:
            self.assertEqual(r["language"], "vi")
            for field in ("query_id", "question", "reference_answer"):
                self.assertTrue(r.get(field), f"{r.get('query_id')} missing {field}")
        self.assertEqual(
            len({r["query_id"] for r in rows}), len(rows), "duplicate query_id"
        )


class ScoringTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def _score(self, sheets: dict[str, list[dict]], out: Path | None = None) -> str:
        paths = []
        for name, rows in sheets.items():
            p = self.tmp / f"{name}.csv"
            write_sheet(p, rows)
            paths.append(str(p))
        argv = sys.argv
        sys.argv = ["score_answer_sheet", *paths] + (["--out", str(out)] if out else [])
        buf = io.StringIO()
        try:
            with redirect_stdout(buf):
                score_tool.main()
        finally:
            sys.argv = argv
        return buf.getvalue()

    def test_reports_means_over_both_raters(self):
        out = self._score(
            {
                "r1": [row("q1", grounded=2), row("q2", grounded=0)],
                "r2": [row("q1", grounded=2), row("q2", grounded=0)],
            }
        )
        self.assertIn("grounded           1.00/2", out)

    def test_flags_a_hard_disagreement(self):
        out = self._score(
            {
                "r1": [row("q1", completeness=0)],
                "r2": [row("q1", completeness=2)],
            }
        )
        self.assertIn("hard disagreements: 1", out)

    def test_an_unsafe_answer_is_named_even_when_only_one_rater_flags_it(self):
        # The average would be 1.0/2 -- unremarkable. The query_id must still surface.
        out = self._score(
            {
                "r1": [row(f"q{i}") for i in range(1, 11)],
                "r2": [row("q1", clinically_safe=0)]
                + [row(f"q{i}") for i in range(2, 11)],
            }
        )
        self.assertIn("UNSAFE ANSWERS (1)", out)
        self.assertRegex(out, r"\bq1\b")

    def test_reports_the_language_split(self):
        # A blended figure would read 1.5 and hide that Vietnamese scored 1.0.
        out = self._score(
            {
                "r1": [
                    row("q1", "en", language_quality=2),
                    row("q2", "vi", language_quality=1),
                ],
                "r2": [
                    row("q1", "en", language_quality=2),
                    row("q2", "vi", language_quality=1),
                ],
            }
        )
        self.assertIn("By language:", out)
        self.assertIn("en (n= 1)", out)
        self.assertIn("vi (n= 1)", out)

    def test_reports_weighted_kappa_and_flags_poor_agreement(self):
        r1 = [row(f"q{i}", grounded=g) for i, g in enumerate([0, 1, 2, 0, 1, 2, 0, 1, 2, 2], start=1)]
        r2 = [row(f"q{i}", grounded=g) for i, g in enumerate([2, 1, 0, 2, 1, 0, 2, 1, 0, 0], start=1)]
        out = self._score({"r1": r1, "r2": r2})
        line = next(l for l in out.splitlines() if l.strip().startswith("grounded"))
        self.assertIn("kw -", line, "systematically opposite raters score below chance")
        self.assertIn("raters diverge", line)

    def test_json_summary_carries_the_kappa(self):
        out_path = self.tmp / "kappa.json"
        rows = [row(f"q{i}", grounded=i % 3) for i in range(1, 7)]
        self._score({"r1": rows, "r2": rows}, out=out_path)
        kappa = json.loads(out_path.read_text())["dimensions"]["grounded"]["weighted_kappa"]
        self.assertEqual(kappa["mean"], 1.0)
        self.assertEqual(kappa["interpretation"], "almost perfect")

    def test_writes_a_json_summary(self):
        out_path = self.tmp / "summary.json"
        self._score({"r1": [row("q1")], "r2": [row("q1")]}, out=out_path)
        payload = json.loads(out_path.read_text())
        self.assertEqual(payload["questions_scored"], 1)
        self.assertIn("grounded", payload["dimensions"])
        self.assertEqual(payload["clinically_unsafe_query_ids"], [])

    def test_rejects_an_out_of_range_score(self):
        with self.assertRaises(SystemExit):
            self._score({"r1": [row("q1", grounded=5)], "r2": [row("q1")]})

    def test_rejects_a_non_numeric_score(self):
        bad = row("q1")
        bad["grounded"] = "good"
        with self.assertRaises(SystemExit):
            self._score({"r1": [bad], "r2": [row("q1")]})

    def test_rejects_an_unscored_sheet_instead_of_reporting_zero(self):
        blank = row("q1")
        for dim in score_tool.DIMENSIONS:
            blank[dim] = ""
        with self.assertRaises(SystemExit):
            self._score({"r1": [blank], "r2": [row("q1")]})

    def test_rejects_raters_who_scored_different_questions(self):
        with self.assertRaises(SystemExit):
            self._score({"r1": [row("q1")], "r2": [row("q99")]})


class WeightedKappaTests(unittest.TestCase):
    """Inter-rater agreement is the number that makes two raters' scores a measurement."""

    def test_identical_ratings_with_variance_agree_perfectly(self):
        self.assertAlmostEqual(score_tool.weighted_kappa([0, 1, 2, 2, 1], [0, 1, 2, 2, 1]), 1.0)

    def test_matches_a_hand_computed_value(self):
        # rater a: 0,0,1,2   rater b: 0,1,1,2   (k = 3, quadratic weights 0 / 0.25 / 1)
        # observed weighted disagreement = 0.25 (one 0-vs-1)
        # expected = sum w_ij * row_i * col_j / n with rows (2,1,1), cols (1,2,1), n = 4
        #          = 0.25*(2*2 + 1*1 + 1*2 + 1*1)/4 + 1*(2*1 + 1*1)/4 = 0.25*8/4 + 3/4 = 1.25
        self.assertAlmostEqual(score_tool.weighted_kappa([0, 0, 1, 2], [0, 1, 1, 2]), 1 - 0.25 / 1.25)

    def test_agrees_with_scikit_learn_when_available(self):
        try:
            from sklearn.metrics import cohen_kappa_score
        except ImportError:
            self.skipTest("scikit-learn not installed")
        import random

        rng = random.Random(7)
        for _ in range(50):
            a = [rng.randint(0, 2) for _ in range(30)]
            b = [min(2, max(0, x + rng.choice([-1, 0, 0, 1]))) for x in a]
            ours = score_tool.weighted_kappa(a, b)
            if ours is None:
                continue
            self.assertAlmostEqual(ours, cohen_kappa_score(a, b, labels=[0, 1, 2], weights="quadratic"), places=9)

    def test_is_undefined_without_variance_or_items(self):
        self.assertIsNone(score_tool.weighted_kappa([2, 2, 2], [2, 2, 2]))
        self.assertIsNone(score_tool.weighted_kappa([1], [1]))

    def test_interpretation_bands(self):
        self.assertEqual(score_tool.interpret_kappa(0.85), "almost perfect")
        self.assertEqual(score_tool.interpret_kappa(0.5), "moderate")
        self.assertEqual(score_tool.interpret_kappa(-0.1), "poor")
        self.assertEqual(score_tool.interpret_kappa(None), "undefined")


class GeneratorCliTests(unittest.TestCase):
    """The generator is what the team will actually run; check it end to end."""

    def test_cli_emits_one_sheet_per_rater_plus_a_separate_key(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            result = subprocess.run(
                [
                    sys.executable,
                    "-m",
                    "tools.make_answer_sheet",
                    "--n",
                    "20",
                    "--raters",
                    "2",
                    "--out",
                    str(out),
                ],
                cwd=PIPELINE,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue((out / "answer_quality_rater1.csv").exists())
            self.assertTrue((out / "answer_quality_rater2.csv").exists())
            self.assertTrue((out / "reference_answers.md").exists())

            with open(out / "answer_quality_rater1.csv", encoding="utf-8") as f:
                r1 = list(csv.DictReader(f))
            with open(out / "answer_quality_rater2.csv", encoding="utf-8") as f:
                r2 = list(csv.DictReader(f))
            self.assertEqual([r["query_id"] for r in r1], [r["query_id"] for r in r2])
            self.assertEqual(len(r1), 20)

            # Score columns must ship empty, and the answer must not be pre-filled.
            for dim in score_tool.DIMENSIONS:
                self.assertTrue(all(r[dim] == "" for r in r1))
            self.assertTrue(all(r["model_answer"] == "" for r in r1))

            # The reference answers must NOT be inside the sheet the rater scores.
            sheet_text = (out / "answer_quality_rater1.csv").read_text(encoding="utf-8")
            key_text = (out / "reference_answers.md").read_text(encoding="utf-8")
            self.assertIn("Reference", key_text)
            self.assertNotIn("**Reference:**", sheet_text)

    def test_sample_is_bilingual(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            subprocess.run(
                [
                    sys.executable,
                    "-m",
                    "tools.make_answer_sheet",
                    "--n",
                    "30",
                    "--raters",
                    "1",
                    "--out",
                    str(out),
                ],
                cwd=PIPELINE,
                capture_output=True,
                text=True,
                check=True,
            )
            with open(out / "answer_quality_rater1.csv", encoding="utf-8") as f:
                rows = list(csv.DictReader(f))
            self.assertTrue(any(r["language"] == "vi" for r in rows))
            self.assertTrue(any(r["language"] == "en" for r in rows))


if __name__ == "__main__":
    unittest.main()
