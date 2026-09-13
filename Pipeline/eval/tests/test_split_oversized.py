"""Tests for ingestion/split_oversized.py.

The first version of the splitter decoded token ids back to text (lower-casing and re-spacing
249 pieces through the uncased vocabulary) and emitted overlap-only duplicates (84 pieces).
These pin the properties that make a split corpus safe to ship: every piece is under the
embedder window, is verbatim source text, and nothing is duplicated or lost.

    cd Pipeline && python -m unittest discover -s eval/tests -t .
"""

from __future__ import annotations

import importlib.util
import json
import re
import tempfile
import unittest
from pathlib import Path

HAS_TOKENIZER = importlib.util.find_spec("transformers") is not None


def _norm(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip()


@unittest.skipUnless(HAS_TOKENIZER, "needs transformers (the bge-small tokenizer)")
class SplitOversizedTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from ingestion import split_oversized as so

        cls.so = so

    def _long_text(self) -> str:
        paragraphs = []
        for p in range(12):
            sentences = [
                f"Paragraph {p} sentence {s}: Contact your Stoma Nurse if the redness around the stoma spreads beyond 2 cm."
                for s in range(9)
            ]
            paragraphs.append(" ".join(sentences))
        return "\n\n".join(paragraphs)

    def test_every_piece_fits_the_window_and_is_source_text(self):
        text = self._long_text()
        pieces = self.so.split_text(text)
        self.assertGreater(len(pieces), 1)
        for piece in pieces:
            self.assertLessEqual(self.so.count_tokens(piece), self.so.MAX_CHUNK_TOKENS)
            # Case and punctuation spacing survive: a piece is the source text, up to whitespace.
            self.assertIn(_norm(piece), _norm(text))
            self.assertIn("Stoma Nurse", piece)

    def test_no_piece_is_duplicated_and_no_word_is_lost(self):
        text = self._long_text()
        pieces = self.so.split_text(text)
        self.assertEqual(len(pieces), len(set(pieces)))
        self.assertEqual(set(text.split()), set(" ".join(pieces).split()))

    def test_an_unpunctuated_run_is_cut_at_whitespace_without_changing_it(self):
        # A table flattened into one "sentence": no paragraph or sentence boundary to use.
        text = " ".join(f"Row{i} Value{i} 12.5mg" for i in range(600))
        for piece in self.so.split_text(text):
            self.assertLessEqual(self.so.count_tokens(piece), self.so.MAX_CHUNK_TOKENS)
            self.assertIn(piece, text)
            self.assertFalse(piece[0].isspace() or piece[-1].isspace())

    def test_a_single_word_longer_than_the_window_is_still_bounded(self):
        text = "https://example.org/" + "a1b2c3d4" * 400
        for piece in self.so.split_text(text):
            self.assertLessEqual(self.so.count_tokens(piece), self.so.MAX_CHUNK_TOKENS)

    def test_an_overlap_is_short_and_never_the_whole_previous_piece(self):
        long_sentence = "This sentence keeps going " + "and going " * 120 + "until it stops."
        self.assertEqual(self.so.overlap_tail(long_sentence, 400), "")
        self.assertEqual(self.so.overlap_tail("First short one. Second short one.", 10), "Second short one.")
        self.assertLessEqual(self.so.count_tokens(self.so.overlap_tail(long_sentence)), self.so.OVERLAP_TOKENS)

    def test_short_text_is_returned_untouched(self):
        self.assertEqual(self.so.split_text("Keep the wound dry."), ["Keep the wound dry."])

    def test_split_file_records_provenance_and_is_idempotent(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "Doc.json"
            path.write_text(
                json.dumps(
                    {"chunks": [
                        {"chunk_index": 1, "text": "Short intro."},
                        {"chunk_index": 2, "text": self._long_text()},
                        {"chunk_index": 3, "text": "Short outro."},
                    ]}
                ),
                encoding="utf-8",
            )
            before, after, split = self.so.split_file(path)
            chunks = json.loads(path.read_text(encoding="utf-8"))["chunks"]
            self.assertEqual((before, split), (3, 1))
            self.assertEqual([c["chunk_index"] for c in chunks], list(range(1, after + 1)))
            self.assertEqual(chunks[0]["source_chunk_index"], 1)
            self.assertEqual(chunks[-1]["source_chunk_index"], 3)
            self.assertTrue(all(c["source_chunk_index"] == 2 for c in chunks[1:-1]))

            first = path.read_text(encoding="utf-8")
            self.assertEqual(self.so.split_file(path)[2], 0, "a split corpus has nothing left to split")
            self.assertEqual(path.read_text(encoding="utf-8"), first)


class RemapByProvenanceTests(unittest.TestCase):
    def test_each_gold_chunk_becomes_the_group_of_its_pieces(self):
        from tools.remap_qrels import remap_by_provenance

        mapping = {"D_c002": ["D_c002", "D_c003", "D_c004"], "D_c001": ["D_c001"]}
        qrels = [
            {"query_id": "q1", "relevant_chunk_ids": ["D_c002"]},
            {"query_id": "q2", "relevant_chunk_ids": ["D_c009"]},
            {"query_id": "q3", "relevant_chunk_ids": ["D_c001"], "relevant_groups": [["D_c001"]]},
        ]
        out, dropped, already = remap_by_provenance(qrels, mapping)
        self.assertEqual(out[0]["relevant_groups"], [["D_c002", "D_c003", "D_c004"]])
        self.assertEqual(out[0]["relevant_chunk_ids"], ["D_c002", "D_c003", "D_c004"])
        self.assertEqual(out[1]["relevant_chunk_ids"], [])
        self.assertEqual(dropped, ["D_c009"])
        self.assertEqual(already, ["q3"], "already-grouped qrels are not remapped twice")


if __name__ == "__main__":
    unittest.main()
