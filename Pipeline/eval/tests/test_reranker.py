"""Tests for the reranking step the eval harness shares with SQLiteRetriever.

Run from Pipeline/:
    python -m unittest eval.tests.test_reranker
"""

from __future__ import annotations

import json
import sqlite3
import struct
import tempfile
import unittest
from pathlib import Path

from eval.provenance import app_retrieval
from eval.reranker import RerankingRetriever, order_by_scores
from eval.retriever import RetrievedChunk


class _Base:
    def __init__(self, texts: list[str]) -> None:
        self.texts = texts
        self.requested_k: list[int] = []

    def search(self, question: str, k: int) -> list[RetrievedChunk]:
        self.requested_k.append(k)
        return [RetrievedChunk(chunk_id=f"D_c{i}", text=t, distance=float(i)) for i, t in enumerate(self.texts[:k])]


class _ScoreByLength:
    """Longer passage = more relevant; records how many pairs it was asked to score."""

    def __init__(self) -> None:
        self.calls: list[int] = []

    def scores(self, question: str, passages: list[str]) -> list[float]:
        self.calls.append(len(passages))
        return [float(len(p)) for p in passages]


class OrderByScoresTests(unittest.TestCase):
    def test_best_first_and_ties_keep_retrieval_order(self):
        # Same expectation as CrossEncoderRerankerTests.testTiesKeepRetrievalOrder.
        self.assertEqual(order_by_scores([0.1, 2.0, 0.1, 2.0]), [1, 3, 0, 2])

    def test_empty(self):
        self.assertEqual(order_by_scores([]), [])


class RerankingRetrieverTests(unittest.TestCase):
    def test_scores_the_candidate_pool_and_keeps_the_best_k(self):
        base = _Base(["a", "bbbb", "cc", "ddddd", "eee"])
        reranker = _ScoreByLength()
        rows = RerankingRetriever(base, reranker, candidates=4).search("q", 2)
        self.assertEqual(base.requested_k, [4])
        self.assertEqual(reranker.calls, [4])
        self.assertEqual([r.chunk_id for r in rows], ["D_c3", "D_c1"])

    def test_pool_is_never_smaller_than_k(self):
        base = _Base(["a", "bb", "ccc"])
        rows = RerankingRetriever(base, _ScoreByLength(), candidates=1).search("q", 3)
        self.assertEqual(base.requested_k, [3], "mirrors max(topK, rerankCandidates) in Swift")
        self.assertEqual([r.chunk_id for r in rows], ["D_c2", "D_c1", "D_c0"])

    def test_a_single_row_is_not_scored(self):
        reranker = _ScoreByLength()
        rows = RerankingRetriever(_Base(["only"]), reranker, candidates=10).search("q", 5)
        self.assertEqual([r.chunk_id for r in rows], ["D_c0"])
        self.assertEqual(reranker.calls, [])

    def test_candidates_must_be_positive(self):
        with self.assertRaises(ValueError):
            RerankingRetriever(_Base([]), _ScoreByLength(), candidates=0)


class AppRerankingTests(unittest.TestCase):
    """What a build reranks with: the bundled model, the shared vocab and the tuning knob."""

    def _resources(self, root: Path, *, reranker: bool, vocab: bool, tuning: dict | None) -> None:
        resources = root / "App" / "Resources"
        resources.mkdir(parents=True)
        if reranker:
            (resources / "reranker.mlpackage").mkdir()
        if vocab:
            (resources / "vocab.txt").write_text("[PAD]")
        if tuning is not None:
            (resources / "InferenceTuning.json").write_text(json.dumps(tuning))

    def test_bundled_model_and_vocab_use_the_tuning_value(self):
        with tempfile.TemporaryDirectory() as tmp:
            self._resources(Path(tmp), reranker=True, vocab=True, tuning={"prompt": {"rerankCandidates": 25}})
            info = app_retrieval(Path(tmp))
            self.assertTrue(info["reranker_bundled"])
            self.assertEqual(info["rerank_candidates"], 25)

    def test_without_the_model_or_the_vocab_nothing_is_reranked(self):
        for reranker, vocab in ((False, True), (True, False)):
            with tempfile.TemporaryDirectory() as tmp:
                self._resources(Path(tmp), reranker=reranker, vocab=vocab, tuning={"prompt": {"rerankCandidates": 25}})
                self.assertEqual(app_retrieval(Path(tmp))["rerank_candidates"], 0)

    def test_an_unreadable_knob_is_reported_as_unknown(self):
        with tempfile.TemporaryDirectory() as tmp:
            self._resources(Path(tmp), reranker=True, vocab=True, tuning={"prompt": {}})
            self.assertIsNone(app_retrieval(Path(tmp))["rerank_candidates"])


class ShippedRerankConfigTests(unittest.TestCase):
    CONFIG = Path(__file__).resolve().parents[1] / "experiment_config.json"

    def test_the_app_experiment_reranks_like_the_bundle(self):
        # If reranker.mlpackage is dropped or rerankCandidates changes, the headline experiment
        # must change with it or it no longer describes the app.
        cfg = json.loads(self.CONFIG.read_text())
        repo_root = self.CONFIG.parents[2]
        exp = next(e for e in cfg["experiments"] if e.get("represents_app"))
        retrieval = {**cfg["retrieval"], **exp.get("retrieval", {})}
        self.assertEqual(int(retrieval.get("rerank_candidates", 0)), app_retrieval(repo_root)["rerank_candidates"])

    def test_the_bundled_tuning_file_sets_the_knob(self):
        tuning = json.loads((self.CONFIG.parents[2] / "App" / "Resources" / "InferenceTuning.json").read_text())
        self.assertIsInstance(tuning["prompt"].get("rerankCandidates"), int)


@unittest.skipUnless(
    __import__("importlib").util.find_spec("sqlite_vec")
    and __import__("importlib").util.find_spec("sentence_transformers"),
    "needs sqlite_vec and sentence_transformers",
)
class RunnerRerankTests(unittest.TestCase):
    class _NoEmbedder:
        def encode(self, *args, **kwargs):
            raise AssertionError("fts mode must not embed")

    def test_rerank_candidates_reorders_what_the_metrics_see(self):
        import sqlite_vec

        from eval.dataset import QrelItem, QueryItem
        from eval.runner import run_experiment

        with tempfile.TemporaryDirectory() as tmp:
            db = Path(tmp) / "i.db"
            conn = sqlite3.connect(db)
            conn.enable_load_extension(True)
            sqlite_vec.load(conn)
            conn.execute("CREATE TABLE chunks (rowid INTEGER PRIMARY KEY, chunk_id TEXT, text TEXT)")
            conn.execute("CREATE VIRTUAL TABLE chunks_fts USING fts5(text, content='chunks', content_rowid='rowid')")
            conn.execute("CREATE VIRTUAL TABLE vec_chunks USING vec0(embedding float[2])")
            texts = ["stoma stoma stoma care", "stoma care at home after surgery, step by step"]
            for i, text in enumerate(texts, start=1):
                conn.execute("INSERT INTO chunks VALUES (?,?,?)", (i, f"D_c{i}", text))
                conn.execute("INSERT INTO vec_chunks(rowid, embedding) VALUES (?, ?)", (i, struct.pack("2f", 1.0, 0.0)))
            conn.execute("INSERT INTO chunks_fts(chunks_fts) VALUES('rebuild')")
            conn.commit()
            conn.close()

            queries = [QueryItem(query_id="q1", question="stoma care")]
            qrels = {"q1": QrelItem(query_id="q1", relevant_chunk_ids=["D_c2"])}
            common = dict(db_path=db, queries=queries, qrels=qrels, embedder=self._NoEmbedder(), top_k=1)

            plain = run_experiment("plain", retrieval={"mode": "fts"}, **common)
            reranked = run_experiment(
                "reranked", retrieval={"mode": "fts", "rerank_candidates": 5}, reranker=_ScoreByLength(), **common
            )
            self.assertEqual(plain["per_query"][0]["retrieved_chunk_ids"], ["D_c1"])
            self.assertEqual(reranked["per_query"][0]["retrieved_chunk_ids"], ["D_c2"])
            self.assertEqual(reranked["retrieval"]["rerank_candidates"], 5)
            self.assertEqual(plain["retrieval"]["rerank_candidates"], 0)
            self.assertIsNone(plain["retrieval"]["rerank_model"])


if __name__ == "__main__":
    unittest.main()
