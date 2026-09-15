"""Tests for qrels pooling, graded metrics and pooled scoring (fake judge, no network).

Run from Pipeline/:
    python -m unittest eval.tests.test_qrels_pooling
"""

from __future__ import annotations

import csv
import json
import math
import tempfile
import unittest
from pathlib import Path

from eval.dataset import QrelItem
from eval.metrics_graded import graded_ndcg_at_k, graded_recall_at_k, judged_at_k
from tools import pool_qrels, score_pooled

QRELS = {
    "q1": QrelItem("q1", ["A_c001", "A_c002"], [["A_c001", "A_c002"]]),
    "q2": QrelItem("q2", ["B_c005"]),
}


def _run(label: str, retrieved: dict[str, list[str]], sha: str = "idx") -> dict:
    return {"label": label, "index_sha256": sha, "retrieved": retrieved}


class ParseGradeTests(unittest.TestCase):
    def test_labelled_bare_and_unparseable_replies(self):
        self.assertEqual(pool_qrels.parse_grade("Grade: 2"), 2)
        self.assertEqual(pool_qrels.parse_grade("reasoning... grade = 1\nGrade: 0"), 0, "last label wins")
        self.assertEqual(pool_qrels.parse_grade(" 1. "), 1)
        self.assertIsNone(pool_qrels.parse_grade("Grade: 3"))
        self.assertIsNone(pool_qrels.parse_grade("I think 2 or 1"))


class PoolTests(unittest.TestCase):
    def test_union_at_depth_without_gold_in_first_seen_order(self):
        runs = [
            _run("hybrid", {"q1": ["A_c002", "C_c001", "D_c001"], "q2": ["B_c005", "E_c001"]}),
            _run("fts", {"q1": ["C_c001", "F_c001", "G_c001"]}),
        ]
        self.assertEqual(
            pool_qrels.pool_candidates(runs, QRELS, depth=2),
            {"q1": ["C_c001", "F_c001"], "q2": ["E_c001"]},
        )

    def test_runs_from_different_indexes_are_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            paths = []
            for i, sha in enumerate(("aaa", "bbb")):
                path = Path(tmp) / f"r{i}.json"
                path.write_text(json.dumps({"experiments": [
                    {"experiment": "e", "provenance": {"index": {"sha256": sha}}, "per_query": []}
                ]}))
                paths.append(path)
            with self.assertRaises(SystemExit):
                pool_qrels.load_runs(paths)
            self.assertEqual(len(pool_qrels.load_runs(paths, allow_mixed_index=True)), 2)


class JudgeTests(unittest.TestCase):
    def test_judgements_are_appended_resumable_and_per_model(self):
        pool = {"q1": ["C_c001", "F_c001"], "q2": ["E_c001"]}
        questions = {"q1": "What is a stoma?", "q2": "Diet?"}
        passages = {"C_c001": "stoma text", "F_c001": "noise", "E_c001": "diet text"}
        calls: list[str] = []

        def judge(system, user):
            calls.append(user)
            return "Grade: 2" if "stoma" in user else ("Grade: 0" if "noise" in user else "maybe")

        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "j.jsonl"
            first = pool_qrels.judge_pool(pool, questions, passages, judge, "m1", path)
            self.assertEqual(first, {"already_judged": 0, "judged": 2, "unparsed": 1})
            self.assertIn("Passage:\nstoma text", calls[0])
            second = pool_qrels.judge_pool(pool, questions, passages, judge, "m1", path)
            self.assertEqual(second, {"already_judged": 2, "judged": 0, "unparsed": 1}, "only the unparsed pair is retried")
            other = pool_qrels.judge_pool(pool, questions, passages, judge, "m2", path)
            self.assertEqual(other["judged"], 2, "another judge model judges afresh")

    def test_pooled_rows_keep_gold_and_separate_zero_grades(self):
        judgments = [
            {"query_id": "q1", "chunk_id": "C_c001", "grade": 1, "judge_model": "m"},
            {"query_id": "q1", "chunk_id": "F_c001", "grade": 0, "judge_model": "m"},
            {"query_id": "q1", "chunk_id": "A_c001", "grade": 0, "judge_model": "m"},
            {"query_id": "q2", "chunk_id": "E_c001", "grade": 2, "judge_model": "other"},
        ]
        rows = {r["query_id"]: r for r in pool_qrels.build_pooled_qrels(QRELS, judgments, "m")}
        self.assertEqual(
            rows["q1"]["groups"],
            [
                {"chunk_ids": ["A_c001", "A_c002"], "grade": 2, "source": "gold"},
                {"chunk_ids": ["C_c001"], "grade": 1, "source": "judge"},
            ],
        )
        self.assertEqual(rows["q1"]["judged_nonrelevant"], ["F_c001"], "a judge never demotes gold")
        self.assertEqual(rows["q2"]["groups"], [{"chunk_ids": ["B_c005"], "grade": 2, "source": "gold"}])


class GradedMetricTests(unittest.TestCase):
    GROUPS = [{"chunk_ids": ["a1", "a2"], "grade": 2}, {"chunk_ids": ["b"], "grade": 1}]

    def test_graded_ndcg_credits_each_group_once(self):
        value = graded_ndcg_at_k(self.GROUPS, ["x", "a2", "b", "a1"], 3)
        self.assertAlmostEqual(value, (3 / math.log2(3) + 1 / 2) / (3 + 1 / math.log2(3)))
        self.assertAlmostEqual(graded_ndcg_at_k(self.GROUPS, ["a1", "b", "a2"], 3), 1.0)
        self.assertEqual(graded_ndcg_at_k([], ["a1"], 3), 0.0)

    def test_recall_by_grade_and_judged_share(self):
        retrieved = ["x", "a2", "b"]
        self.assertEqual(graded_recall_at_k(self.GROUPS, retrieved, 3, 2), 1.0)
        self.assertEqual(graded_recall_at_k(self.GROUPS, retrieved, 2, 1), 0.5)
        self.assertEqual(judged_at_k(self.GROUPS, [], retrieved, 3), 2 / 3)
        self.assertEqual(judged_at_k(self.GROUPS, ["x"], retrieved, 3), 1.0)


class AgreementAndScoringTests(unittest.TestCase):
    def test_agreement_skips_ungraded_rows(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "s.csv"
            with path.open("w", newline="") as f:
                writer = csv.writer(f)
                writer.writerow(["query_id", "chunk_id", "question", "passage", "judge_grade", "human_grade"])
                for judge_grade, human in ((2, "2"), (1, "1"), (0, "0"), (2, "1"), (0, "")):
                    writer.writerow(["q", "c", "Q", "P", judge_grade, human])
            report = pool_qrels.agreement(path)
            self.assertEqual(report["pairs"], 4)
            self.assertEqual(report["exact_agreement"], 0.75)
            self.assertGreater(report["weighted_kappa"], 0.6)

    def test_score_pooled_reports_gold_and_graded_side_by_side(self):
        pooled = [
            {"query_id": "q1", "groups": [{"chunk_ids": ["A_c001"], "grade": 2, "source": "gold"},
                                           {"chunk_ids": ["C_c001"], "grade": 2, "source": "judge"}],
             "judged_nonrelevant": ["X_c001"]},
        ]
        result = {"config": {"evaluation": {"top_k": 2}}, "experiments": [
            {"experiment": "hybrid", "metrics": {"recall@k": 0.0},
             "per_query": [{"query_id": "q1", "retrieved_chunk_ids": ["X_c001", "C_c001"]}]}
        ]}
        [row] = score_pooled.score(pooled, result)
        self.assertEqual(row["recall_gold"], 0.0)
        self.assertEqual(row["recall_grade2"], 0.5)
        self.assertEqual(row["judged_at_k"], 1.0)
        with self.assertRaises(SystemExit):
            score_pooled.score([], result)


if __name__ == "__main__":
    unittest.main()
