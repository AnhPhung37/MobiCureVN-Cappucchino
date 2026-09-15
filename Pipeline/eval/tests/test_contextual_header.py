"""Tests for the contextual header on chunk embeddings.

Run from Pipeline/:
    python -m unittest eval.tests.test_contextual_header
"""

from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from ingestion.contextual_header import embedding_text, humanize_title, load_titles


class HeaderTests(unittest.TestCase):
    TITLES = {"BCUK_ASR_2024": "Bowel Cancer UK About Stoma Reversal 2024"}

    def test_titles_come_from_the_registry_humanized(self):
        self.assertEqual(
            humanize_title("Bowel_Cancer_UK_About_Stoma_Reversal_2024"),
            "Bowel Cancer UK About Stoma Reversal 2024",
        )
        with tempfile.TemporaryDirectory() as tmp:
            registry = Path(tmp) / "registry.csv"
            registry.write_text(
                "doc_id,title,source_org\nBCUK_ASR_2024,Bowel_Cancer_UK_About_Stoma_Reversal_2024,BCUK\n"
            )
            self.assertEqual(load_titles(registry), self.TITLES)

    def test_header_is_title_and_section_above_the_text(self):
        chunk = {
            "doc_id": "BCUK_ASR_2024",
            "section": "## What happens after reversal",
            "text": "Your bowel may be unsettled.",
        }
        self.assertEqual(
            embedding_text(chunk, self.TITLES),
            "Bowel Cancer UK About Stoma Reversal 2024 › What happens after reversal\n\nYour bowel may be unsettled.",
        )

    def test_missing_parts_and_the_switch_off(self):
        text = {"doc_id": "BCUK_ASR_2024", "section": None, "text": "t"}
        self.assertEqual(
            embedding_text(text, self.TITLES),
            "Bowel Cancer UK About Stoma Reversal 2024\n\nt",
        )
        self.assertEqual(
            embedding_text(
                {"doc_id": "UNKNOWN", "section": "", "text": "t"}, self.TITLES
            ),
            "t",
        )
        self.assertEqual(
            embedding_text(
                {"doc_id": "BCUK_ASR_2024", "section": "S", "text": "t"}, None
            ),
            "t",
        )


@unittest.skipUnless(
    importlib.util.find_spec("sqlite_vec")
    and importlib.util.find_spec("sentence_transformers"),
    "needs sqlite_vec and sentence_transformers",
)
class IndexBuilderTests(unittest.TestCase):
    def test_header_reaches_the_embedder_but_not_the_stored_text(self):
        import sqlite3

        import numpy as np

        from eval import index_builder

        seen: list[str] = []

        class FakeModel:
            def __init__(self, name):
                pass

            def encode(self, texts, **kwargs):
                seen.extend(texts)
                return np.ones((len(texts), 2), dtype=np.float32)

        with tempfile.TemporaryDirectory() as tmp:
            enriched = Path(tmp) / "enriched"
            enriched.mkdir()
            (enriched / "D.json").write_text(
                json.dumps(
                    {
                        "chunks": [
                            {
                                "chunk_id": "D_c001",
                                "doc_id": "D",
                                "text": "stoma care",
                                "section": "Care",
                            }
                        ]
                    }
                )
            )
            db = Path(tmp) / "i.db"
            with mock.patch.object(index_builder, "SentenceTransformer", FakeModel):
                index_builder.build_index(
                    enriched, db, "fake", 2, 8, titles={"D": "Doc Title"}
                )
            self.assertEqual(seen, ["Doc Title › Care\n\nstoma care"])
            conn = sqlite3.connect(db)
            self.assertEqual(
                conn.execute("SELECT text FROM chunks").fetchone()[0], "stoma care"
            )
            conn.close()


class ConfigTests(unittest.TestCase):
    def test_only_the_header_switch_may_vary_per_experiment(self):
        cfg = json.loads(
            (Path(__file__).resolve().parents[1] / "experiment_config.json").read_text()
        )
        for exp in cfg["experiments"]:
            self.assertLessEqual(
                set(exp.get("embed", {})), {"contextual_header"}, exp["name"]
            )
        contextual = [
            e for e in cfg["experiments"] if e.get("embed", {}).get("contextual_header")
        ]
        self.assertTrue(contextual)
        self.assertTrue(
            any(e.get("represents_app") for e in contextual),
            "App/Resources/vectorstore.db ships with the header",
        )


if __name__ == "__main__":
    unittest.main()
