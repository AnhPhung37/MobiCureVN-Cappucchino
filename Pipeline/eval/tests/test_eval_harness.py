"""Tests for the evaluation harness itself.

The harness shipped two defects that silently produced wrong numbers for months:
a golden set that leaked its labels, then an index built from 9 of 39 documents
while the answer key spanned all 39. Neither was caught because nothing tested the
measuring instrument.

These tests lock in the guards. Run with:

    cd Pipeline && python -m unittest discover -s eval/tests -t .
"""

from __future__ import annotations

import json
import sqlite3
import struct
import tempfile
import unittest
from pathlib import Path

from eval.dataset import QrelItem
from eval.metrics_ir import doc_hit_at_k, doc_id_of, mrr, ndcg_at_k, recall_at_k
from eval.provenance import (
    app_retrieval,
    config_digest,
    corpus_fingerprint,
    git_state,
    index_fingerprint,
    qrels_coverage,
    repo_relative,
)


def _make_index(path: Path, chunk_ids: list[str]) -> None:
    """A minimal stand-in for a built index: just the `chunks` table the
    provenance helpers read."""
    conn = sqlite3.connect(path)
    conn.execute(
        "CREATE TABLE chunks (rowid INTEGER PRIMARY KEY, chunk_id TEXT UNIQUE, "
        "doc_id TEXT, text TEXT)"
    )
    for i, cid in enumerate(chunk_ids, start=1):
        conn.execute(
            "INSERT INTO chunks (rowid, chunk_id, doc_id, text) VALUES (?,?,?,?)",
            (i, cid, doc_id_of(cid), f"text {i}"),
        )
    conn.commit()
    conn.close()


class DocIdParsingTests(unittest.TestCase):
    def test_splits_on_the_chunk_suffix(self):
        self.assertEqual(doc_id_of("ACS_CCFS_c011"), "ACS_CCFS")
        self.assertEqual(doc_id_of("BCUK_CS_V2.1_2023_c007"), "BCUK_CS_V2.1_2023")

    def test_doc_ids_containing_c_are_not_truncated(self):
        # "_c" appears inside plenty of doc IDs; only a trailing _c<digits> is a
        # chunk suffix. Getting this wrong would silently inflate doc-hit.
        self.assertEqual(doc_id_of("UOAA_NOPG_2024_c156"), "UOAA_NOPG_2024")
        self.assertEqual(doc_id_of("WOCN_cath_2018"), "WOCN_cath_2018")

    def test_id_without_a_suffix_is_returned_unchanged(self):
        self.assertEqual(doc_id_of("PLAIN"), "PLAIN")


class DocHitTests(unittest.TestCase):
    def test_exact_gold_chunk_counts_as_a_hit(self):
        self.assertEqual(doc_hit_at_k({"A_c1"}, ["A_c1", "B_c2"], 5), 1.0)

    def test_neighbour_chunk_from_the_right_document_counts(self):
        # This is the entire point of the metric: recall@k scores 0 here, but the
        # retrieved chunk came from the document that holds the answer.
        self.assertEqual(doc_hit_at_k({"A_c1"}, ["A_c9"], 5), 1.0)
        self.assertEqual(recall_at_k({"A_c1"}, ["A_c9"], 5), 0.0)

    def test_wrong_document_is_not_a_hit(self):
        self.assertEqual(doc_hit_at_k({"A_c1"}, ["B_c1", "C_c2"], 5), 0.0)

    def test_respects_the_k_cutoff(self):
        retrieved = ["X_c1", "X_c2", "X_c3", "X_c4", "X_c5", "A_c1"]
        self.assertEqual(doc_hit_at_k({"A_c1"}, retrieved, 5), 0.0)
        self.assertEqual(doc_hit_at_k({"A_c1"}, retrieved, 6), 1.0)

    def test_empty_relevant_set_scores_zero_rather_than_dividing_by_zero(self):
        self.assertEqual(doc_hit_at_k(set(), ["A_c1"], 5), 0.0)


class ExistingMetricsRegressionTests(unittest.TestCase):
    """The corrected config changes what is measured; these pin down how."""

    def test_recall_is_the_fraction_of_gold_chunks_found(self):
        self.assertEqual(recall_at_k({"A_c1", "A_c2"}, ["A_c1", "B_c1"], 5), 0.5)

    def test_recall_at_k_ignores_hits_past_k(self):
        self.assertEqual(recall_at_k({"A_c1"}, ["B_c1", "B_c2", "A_c1"], 2), 0.0)

    def test_mrr_is_the_reciprocal_rank_of_the_first_hit(self):
        self.assertAlmostEqual(mrr({"A_c1"}, ["X_c1", "A_c1"]), 0.5)
        self.assertEqual(mrr({"A_c1"}, ["X_c1", "X_c2"]), 0.0)

    def test_ndcg_is_one_when_the_only_gold_chunk_ranks_first(self):
        self.assertAlmostEqual(ndcg_at_k({"A_c1"}, ["A_c1", "B_c1"], 5), 1.0)

    def test_single_gold_chunk_makes_recall_equal_a_hit_rate(self):
        # 207 of the 209 golden queries label exactly one chunk, so recall@5
        # degenerates into "was that one chunk in the top 5". Worth asserting,
        # because it is why recall@5 reads so much lower than doc-hit@5.
        self.assertEqual(recall_at_k({"A_c1"}, ["A_c1"], 5), 1.0)
        self.assertEqual(recall_at_k({"A_c1"}, ["A_c2"], 5), 0.0)


class QrelsCoverageTests(unittest.TestCase):
    """Regression test for the defect that capped recall at 0.367."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def _qrels(self, ids: list[str]) -> dict:
        return {
            f"q{i:03d}": QrelItem(query_id=f"q{i:03d}", relevant_chunk_ids=[cid])
            for i, cid in enumerate(ids, start=1)
        }

    def test_full_coverage_when_every_gold_chunk_is_indexed(self):
        db = self.tmp / "full.db"
        _make_index(db, ["A_c1", "A_c2", "B_c1"])
        result = qrels_coverage(self._qrels(["A_c1", "A_c2", "B_c1"]), db)
        self.assertEqual(result["coverage"], 1.0)
        self.assertEqual(result["present_in_index"], 3)
        self.assertEqual(result["max_achievable_recall"], 1.0)

    def test_partial_index_reports_the_recall_ceiling_it_imposes(self):
        # The shipped defect in miniature: the answer key spans documents the
        # index under test does not contain.
        db = self.tmp / "partial.db"
        _make_index(db, ["A_c1", "A_c2"])
        result = qrels_coverage(self._qrels(["A_c1", "A_c2", "B_c1", "B_c2"]), db)
        self.assertEqual(result["present_in_index"], 2)
        self.assertEqual(result["coverage"], 0.5)
        self.assertEqual(result["max_achievable_recall"], 0.5)

    def test_missing_index_does_not_raise(self):
        result = qrels_coverage(self._qrels(["A_c1"]), self.tmp / "nope.db")
        self.assertIsNone(result["coverage"])

    def test_index_without_a_chunks_table_does_not_raise(self):
        db = self.tmp / "empty.db"
        sqlite3.connect(db).close()  # the state eval/outputs was actually found in
        result = qrels_coverage(self._qrels(["A_c1"]), db)
        self.assertIsNone(result["coverage"])


class IndexFingerprintTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def test_reports_chunk_and_document_counts(self):
        db = self.tmp / "i.db"
        _make_index(db, ["A_c1", "A_c2", "B_c1"])
        fp = index_fingerprint(db)
        self.assertEqual(fp["chunk_count"], 3)
        self.assertEqual(fp["doc_count"], 2)
        self.assertIn("chunks", fp["tables"])
        self.assertEqual(len(fp["sha256"]), 64)

    def test_two_different_indexes_do_not_share_a_digest(self):
        a, b = self.tmp / "a.db", self.tmp / "b.db"
        _make_index(a, ["A_c1"])
        _make_index(b, ["A_c1", "A_c2"])
        self.assertNotEqual(
            index_fingerprint(a)["sha256"], index_fingerprint(b)["sha256"]
        )

    def test_absent_index_is_reported_not_raised(self):
        fp = index_fingerprint(self.tmp / "missing.db")
        self.assertFalse(fp["exists"])
        self.assertIsNone(fp["sha256"])


class CorpusFingerprintTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def test_counts_files_and_changes_digest_with_content(self):
        (self.tmp / "a.json").write_text('{"chunks": []}')
        first = corpus_fingerprint(self.tmp)
        self.assertEqual(first["file_count"], 1)

        (self.tmp / "a.json").write_text('{"chunks": [1]}')
        self.assertNotEqual(
            corpus_fingerprint(self.tmp)["files_sha256"], first["files_sha256"]
        )

    def test_adding_a_document_changes_the_digest(self):
        # A 9-doc corpus and a 39-doc corpus must never fingerprint alike.
        (self.tmp / "a.json").write_text("{}")
        nine = corpus_fingerprint(self.tmp)["files_sha256"]
        (self.tmp / "b.json").write_text("{}")
        self.assertNotEqual(corpus_fingerprint(self.tmp)["files_sha256"], nine)

    def test_missing_directory_is_reported_not_raised(self):
        fp = corpus_fingerprint(self.tmp / "nope")
        self.assertFalse(fp["exists"])
        self.assertEqual(fp["file_count"], 0)


class GitStateTests(unittest.TestCase):
    def test_a_clean_tree_reports_dirty_false_not_unknown(self):
        # Empty stdout from `git status --porcelain` is an answer, not a failure.
        with tempfile.TemporaryDirectory() as tmp:
            import subprocess

            root = Path(tmp)
            subprocess.run(["git", "init", "-q"], cwd=root, check=True)
            subprocess.run(["git", "config", "user.email", "t@t"], cwd=root, check=True)
            subprocess.run(["git", "config", "user.name", "t"], cwd=root, check=True)
            (root / "f.txt").write_text("x")
            subprocess.run(["git", "add", "."], cwd=root, check=True)
            subprocess.run(["git", "commit", "-qm", "init"], cwd=root, check=True)

            state = git_state(root)
            self.assertIs(state["dirty"], False)
            self.assertIsNotNone(state["commit"])

            (root / "f.txt").write_text("y")
            self.assertIs(git_state(root)["dirty"], True)

    def test_the_harness_own_outputs_do_not_dirty_the_tree(self):
        # Three back-to-back runs must all report dirty=false on a clean checkout: run 1's
        # result file must not make run 2 look like it ran on modified code.
        with tempfile.TemporaryDirectory() as tmp:
            import subprocess

            root = Path(tmp)
            subprocess.run(["git", "init", "-q"], cwd=root, check=True)
            subprocess.run(["git", "config", "user.email", "t@t"], cwd=root, check=True)
            subprocess.run(["git", "config", "user.name", "t"], cwd=root, check=True)
            (root / "Pipeline" / "eval").mkdir(parents=True)
            (root / "Pipeline" / "eval" / "run_eval.py").write_text("x")
            subprocess.run(["git", "add", "."], cwd=root, check=True)
            subprocess.run(["git", "commit", "-qm", "init"], cwd=root, check=True)

            (root / "Pipeline" / "eval" / "results").mkdir()
            (root / "Pipeline" / "eval" / "results" / "eval_1.json").write_text("{}")
            (root / "Pipeline" / "eval" / "outputs").mkdir()
            (root / "Pipeline" / "eval" / "outputs" / "index.db").write_text("")
            self.assertIs(git_state(root)["dirty"], False)

            (root / "Pipeline" / "eval" / "run_eval.py").write_text("changed")
            self.assertIs(git_state(root)["dirty"], True, "a code change is still dirty")

    def test_non_repository_reports_unknown_rather_than_raising(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = git_state(Path(tmp))
            self.assertIsNone(state["commit"])
            self.assertIsNone(state["dirty"])


class AppRetrievalTests(unittest.TestCase):
    """The eval can only claim to describe the app if the app ships the vector pass."""

    def test_without_the_bundled_embedder_the_app_is_fts_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "App" / "Resources").mkdir(parents=True)
            self.assertEqual(app_retrieval(root)["mode"], "fts")
            (root / "App" / "Resources" / "vocab.txt").write_text("[PAD]")
            self.assertEqual(app_retrieval(root)["mode"], "fts", "vocab alone is not enough")

    def test_with_embedder_and_vocab_the_app_is_hybrid(self):
        with tempfile.TemporaryDirectory() as tmp:
            resources = Path(tmp) / "App" / "Resources"
            (resources / "query_embedder.mlpackage").mkdir(parents=True)
            (resources / "vocab.txt").write_text("[PAD]")
            self.assertEqual(app_retrieval(Path(tmp))["mode"], "hybrid")


@unittest.skipUnless(
    __import__("importlib").util.find_spec("sqlite_vec")
    and __import__("importlib").util.find_spec("sentence_transformers"),
    "needs sqlite_vec and sentence_transformers",
)
class FtsOnlyModeTests(unittest.TestCase):
    """mode=fts must never touch the embedder -- that is what makes it FTS-only."""

    class _ExplodingEmbedder:
        def encode(self, *args, **kwargs):
            raise AssertionError("the vector pass ran")

    def _index(self, path: Path) -> None:
        import sqlite_vec

        conn = sqlite3.connect(path)
        conn.enable_load_extension(True)
        sqlite_vec.load(conn)
        conn.execute("CREATE TABLE chunks (rowid INTEGER PRIMARY KEY, chunk_id TEXT, text TEXT)")
        conn.execute("CREATE VIRTUAL TABLE chunks_fts USING fts5(text, content='chunks', content_rowid='rowid')")
        conn.execute("CREATE VIRTUAL TABLE vec_chunks USING vec0(embedding float[2])")
        for i, text in enumerate(["stoma care at home", "diet after surgery"], start=1):
            conn.execute("INSERT INTO chunks VALUES (?,?,?)", (i, f"D_c{i}", text))
            conn.execute("INSERT INTO vec_chunks(rowid, embedding) VALUES (?, ?)", (i, struct.pack("2f", 1.0, 0.0)))
        conn.execute("INSERT INTO chunks_fts(chunks_fts) VALUES('rebuild')")
        conn.commit()
        conn.close()

    def test_fts_mode_returns_keyword_hits_without_embedding_the_query(self):
        from eval.retriever import HybridRetriever

        with tempfile.TemporaryDirectory() as tmp:
            db = Path(tmp) / "i.db"
            self._index(db)
            fts = HybridRetriever(db, self._ExplodingEmbedder(), always_fuse=True, use_vector=False)
            self.assertEqual([c.chunk_id for c in fts.search("stoma care", 5)], ["D_c1"])

            hybrid = HybridRetriever(db, self._ExplodingEmbedder(), always_fuse=True)
            with self.assertRaises(AssertionError):
                hybrid.search("stoma care", 5)


class RepoRelativeTests(unittest.TestCase):
    def test_paths_inside_the_repo_are_recorded_relative_to_it(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            (repo / "Pipeline" / "eval").mkdir(parents=True)
            self.assertEqual(
                repo_relative(repo / "Pipeline" / "eval" / "x.db", repo),
                str(Path("Pipeline") / "eval" / "x.db"),
            )

    def test_paths_outside_the_repo_are_kept_as_given(self):
        with tempfile.TemporaryDirectory() as repo, tempfile.TemporaryDirectory() as other:
            outside = Path(other) / "x.db"
            self.assertEqual(repo_relative(outside, Path(repo)), str(outside))


class ConfigDigestTests(unittest.TestCase):
    def test_key_order_does_not_change_the_digest(self):
        self.assertEqual(
            config_digest({"a": 1, "b": 2}),
            config_digest({"b": 2, "a": 1}),
        )

    def test_a_changed_value_changes_the_digest(self):
        self.assertNotEqual(config_digest({"top_k": 5}), config_digest({"top_k": 10}))


class ShippedConfigTests(unittest.TestCase):
    """The config is the artifact that was actually wrong; assert its shape."""

    CONFIG = Path(__file__).resolve().parents[1] / "experiment_config.json"

    def setUp(self):
        self.cfg = json.loads(self.CONFIG.read_text())

    def test_enabled_experiments_point_at_the_full_corpus(self):
        for exp in self.cfg["experiments"]:
            if exp.get("enabled", True):
                self.assertIn(
                    "data/",
                    exp["source_chunks_dir"],
                    f"{exp['name']} must read the data/ corpus, not the 9-doc legacy tree",
                )

    def test_every_disabled_experiment_explains_itself(self):
        for exp in self.cfg["experiments"]:
            if not exp.get("enabled", True):
                self.assertTrue(
                    exp.get("disabled_reason"),
                    f"{exp['name']} is disabled with no recorded reason",
                )

    def test_retrieval_block_mirrors_the_shipped_swift_retriever(self):
        # SQLiteRetriever.swift always fuses and drops stopwords. An eval that does
        # not is measuring a retriever the app does not have.
        retrieval = self.cfg["retrieval"]
        self.assertTrue(retrieval["always_fuse"])
        self.assertTrue(retrieval["drop_stopwords"])

    def test_exactly_one_experiment_stands_for_the_app(self):
        self.assertEqual(sum(bool(e.get("represents_app")) for e in self.cfg["experiments"]), 1)

    def test_the_app_experiment_scores_the_retriever_this_tree_ships(self):
        # Ties the headline number to the bundle: if query_embedder.mlpackage is removed,
        # this fails instead of the eval quietly describing a retriever the app lacks.
        repo_root = self.CONFIG.parents[2]
        exp = next(e for e in self.cfg["experiments"] if e.get("represents_app"))
        mode = {**self.cfg["retrieval"], **exp.get("retrieval", {})}.get("mode", "hybrid")
        self.assertEqual(mode, app_retrieval(repo_root)["mode"])

    def test_at_least_one_experiment_is_enabled(self):
        self.assertTrue(any(e.get("enabled", True) for e in self.cfg["experiments"]))


if __name__ == "__main__":
    unittest.main()
