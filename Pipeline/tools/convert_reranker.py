"""
convert_reranker.py

Exports the cross-encoder reranker (cross-encoder/ms-marco-MiniLM-L6-v2) to CoreML for
`App/Backend/Services/RAG/CrossEncoderReranker.swift`, with a parity fixture the Swift tests
check against. Same discipline as `convert_embedder.py`:

  1. the Python mirror of the Swift pair encoding ([CLS] query [SEP] passage [SEP], longest-first
     truncation) must reproduce the Hugging Face tokenizer on every parity pair;
  2. the module being exported must reproduce the reference model's logit, and so must
     sentence-transformers' CrossEncoder.predict, which the eval harness ranks with;
  3. the exported program must match again before it is converted, and the CoreML model's I/O
     types must be what the Swift code reads.

The reranker reuses the query embedder's `App/Resources/vocab.txt`: both models use the
bert-base-uncased vocabulary, and the script refuses to run if that stops being true.

Run from Pipeline/ (CPU is enough):
    python -m tools.convert_reranker

Outputs:
    App/Resources/reranker.mlpackage
    MobiCureVNTests/Fixtures/RerankerParity.json
"""

from __future__ import annotations

import argparse
import json
import shutil
from pathlib import Path

import numpy as np
import torch

_PIPELINE = Path(__file__).resolve().parent.parent
_REPO = _PIPELINE.parent

MODEL_ID = "cross-encoder/ms-marco-MiniLM-L6-v2"
EMBEDDER_ID = "BAAI/bge-small-en-v1.5"
MAX_SEQ_LEN = 512  # CrossEncoderReranker.maxSeqLen

_LONG_PASSAGE = " ".join(
    f"Step {i}: empty the pouch when it is a third full and check the skin around the stoma for redness."
    for i in range(60)
)
PARITY_PAIRS = [
    ("What are the signs of a stoma infection?", "Redness, swelling, warmth or pus around the stoma can be signs of infection. Contact your stoma nurse."),
    ("What are the signs of a stoma infection?", "Eat small, frequent meals and drink plenty of fluids after bowel surgery."),
    ("Can I shower with a colostomy bag?", "Yes. You can shower with or without your pouch; water will not get into the stoma."),
    ("Café résumé: 38°C fever after surgery?", "A temperature above 38°C in the first weeks after surgery needs a call to your surgical team."),
    ("How often should I change my pouch?", _LONG_PASSAGE),  # passage truncated
    (_LONG_PASSAGE[:2400], "Empty the pouch when it is a third full."),  # query truncated
    (_LONG_PASSAGE[:1800], _LONG_PASSAGE),  # both sides long: exercises longest-first ties
]


def encode_pair(query_ids: list[int], passage_ids: list[int], max_len: int = MAX_SEQ_LEN) -> dict:
    """Mirror of CrossEncoderReranker.encodePair (Swift).

    Truncation is the tokenizers library's `longest_first` for a pair, which is not "drop one
    token at a time from the longer side": a side no longer than half the room is kept whole and
    the other takes the rest; when both are longer, the shorter side (the query on a tie) gets
    the floor of half and the longer side the remainder.
    """
    room = max_len - 3
    q, p = list(query_ids), list(passage_ids)
    if len(q) + len(p) > room:
        half = room // 2
        if len(q) <= len(p):
            q = q[:half]
            p = p[: room - len(q)]
        else:
            p = p[:half]
            q = q[: room - len(p)]
    ids = [101] + q + [102] + p + [102]
    types = [0] * (len(q) + 2) + [1] * (len(p) + 1)
    pad = max_len - len(ids)
    return {
        "input_ids": ids + [0] * pad,
        "token_type_ids": types + [0] * pad,
        "attention_mask": [1] * len(ids) + [0] * pad,
    }


class PairScorer(torch.nn.Module):
    """BertForSequenceClassification from its submodules (transformers 5's masking utilities do
    not survive export), with an FP16-safe additive mask.

    Position ids are passed explicitly: at the full 512-token length BertEmbeddings' own
    `position_ids[:, :seq_len]` slice exports as `aten.alias`, which coremltools cannot convert.
    """

    def __init__(self, model: torch.nn.Module):
        super().__init__()
        self.embeddings = model.bert.embeddings
        self.encoder = model.bert.encoder
        self.pooler = model.bert.pooler
        self.classifier = model.classifier
        self.register_buffer("position_ids", torch.arange(MAX_SEQ_LEN).unsqueeze(0), persistent=False)

    def forward(self, input_ids, token_type_ids, attention_mask):
        hidden = self.embeddings(
            input_ids=input_ids, token_type_ids=token_type_ids, position_ids=self.position_ids
        )
        mask = attention_mask[:, None, None, :].to(hidden.dtype)
        hidden = self.encoder(hidden, attention_mask=(1.0 - mask) * -1e4)[0]
        return self.classifier(self.pooler(hidden))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out-dir", type=Path, default=_REPO / "App" / "Resources")
    parser.add_argument("--fixture", type=Path, default=_REPO / "MobiCureVNTests" / "Fixtures" / "RerankerParity.json")
    args = parser.parse_args()

    import coremltools as ct
    from huggingface_hub import hf_hub_download
    from sentence_transformers import CrossEncoder
    from transformers import AutoModelForSequenceClassification, AutoTokenizer

    if Path(hf_hub_download(MODEL_ID, "vocab.txt")).read_text() != Path(hf_hub_download(EMBEDDER_ID, "vocab.txt")).read_text():
        raise SystemExit("the reranker no longer shares the embedder's vocab.txt; bundle its own")

    tokenizer = AutoTokenizer.from_pretrained(MODEL_ID)
    model = AutoModelForSequenceClassification.from_pretrained(MODEL_ID, attn_implementation="eager").eval()
    scorer = PairScorer(model).eval()
    cross_encoder = CrossEncoder(MODEL_ID, max_length=MAX_SEQ_LEN, device="cpu")

    cases = []
    with torch.no_grad():
        for query, passage in PARITY_PAIRS:
            reference = tokenizer(query, passage, truncation="longest_first", max_length=MAX_SEQ_LEN, padding="max_length")
            mirrored = encode_pair(
                tokenizer(query, add_special_tokens=False)["input_ids"],
                tokenizer(passage, add_special_tokens=False)["input_ids"],
            )
            for key in ("input_ids", "token_type_ids", "attention_mask"):
                if mirrored[key] != reference[key]:
                    raise SystemExit(f"pair encoding mirror disagrees with the tokenizer on {key} for {query[:40]!r}")
            tensors = [torch.tensor([mirrored[k]]) for k in ("input_ids", "token_type_ids", "attention_mask")]
            logit = float(model(input_ids=tensors[0], token_type_ids=tensors[1], attention_mask=tensors[2]).logits[0, 0])
            ours = float(scorer(*tensors)[0, 0])
            harness = float(cross_encoder.predict([(query, passage)], show_progress_bar=False)[0])
            if abs(ours - logit) > 1e-4 or abs(harness - logit) > 1e-3:
                raise SystemExit(f"score parity failed for {query[:40]!r}: reference {logit}, module {ours}, CrossEncoder {harness}")
            cases.append({"query": query, "passage": passage, **mirrored, "score": round(logit, 5)})
    print(f"parity: {len(cases)} pairs; encoding mirror, exported module and CrossEncoder agree")

    example = [torch.tensor([cases[0][k]]) for k in ("input_ids", "token_type_ids", "attention_mask")]
    with torch.no_grad():
        exported = torch.export.export(scorer, tuple(example))
        check = [torch.tensor([cases[4][k]]) for k in ("input_ids", "token_type_ids", "attention_mask")]
        if abs(float(exported.module()(*check)[0, 0]) - cases[4]["score"]) > 1e-3:
            raise SystemExit("exported program diverges from the eager module")

    mlmodel = ct.convert(
        exported.run_decompositions({}),
        inputs=[ct.TensorType(name=n, shape=(1, MAX_SEQ_LEN), dtype=np.int32) for n in ("input_ids", "token_type_ids", "attention_mask")],
        outputs=[ct.TensorType(name="score", dtype=np.float32)],
        minimum_deployment_target=ct.target.iOS17,
        compute_precision=ct.precision.FLOAT16,
        compute_units=ct.ComputeUnit.CPU_AND_NE,
    )
    spec = mlmodel.get_spec().description
    io_types = {
        f.name: ct.proto.FeatureTypes_pb2.ArrayFeatureType.ArrayDataType.Name(f.type.multiArrayType.dataType)
        for f in list(spec.input) + list(spec.output)
    }
    expected = {"input_ids": "INT32", "token_type_ids": "INT32", "attention_mask": "INT32", "score": "FLOAT32"}
    if io_types != expected:
        raise SystemExit(f"model I/O {io_types} does not match what CrossEncoderReranker.swift reads: {expected}")
    mlmodel.short_description = f"{MODEL_ID} relevance logit for [CLS] query [SEP] passage [SEP], {MAX_SEQ_LEN} tokens"

    args.out_dir.mkdir(parents=True, exist_ok=True)
    model_path = args.out_dir / "reranker.mlpackage"
    if model_path.exists():
        shutil.rmtree(model_path)
    mlmodel.save(str(model_path))
    # torch.export conversion leaves a debug map in the package that the app never reads.
    (model_path / "executorch_debug_handle_mapping.json").unlink(missing_ok=True)

    args.fixture.parent.mkdir(parents=True, exist_ok=True)
    args.fixture.write_text(
        json.dumps({"model": MODEL_ID, "max_seq_len": MAX_SEQ_LEN, "max_score_delta": 0.05, "cases": cases}, ensure_ascii=False)
        + "\n",
        encoding="utf-8",
    )
    size_mb = sum(f.stat().st_size for f in model_path.rglob("*") if f.is_file()) / 1_000_000
    print(f"Saved {model_path} ({size_mb:.1f} MB) and {args.fixture}")


if __name__ == "__main__":
    main()
