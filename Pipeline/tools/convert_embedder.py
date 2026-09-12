"""
convert_embedder.py

Exports the retrieval embedder to CoreML for on-device QUERY embedding, together with the
WordPiece vocabulary the Swift tokenizer reads and a parity fixture the Swift tests check
against.

The corpus side of the index is embedded in Python by `SentenceTransformer(EMBED_MODEL)`
(`ingestion/build_index.py`, `eval/index_builder.py`). The query side is embedded on the
device by this model. Vector search is only meaningful when both sides produce the SAME
vector for the same text, so this script:

  1. reads the pooling mode from the SentenceTransformer config instead of assuming one
     (bge-small-en-v1.5 pools the [CLS] token; an earlier version of this script mean-pooled,
     which would have put every query in a different space from the documents);
  2. refuses to convert unless the exported module matches SentenceTransformer.encode to
     cosine >= 0.9999 on the parity texts;
  3. writes those texts' token ids and embeddings to a fixture that
     `MobiCureVNTests/QueryEmbedderParityTests.swift` compares the Swift tokenizer and the
     CoreML model against.

Run from Pipeline/ (CPU is enough; conversion itself does not need a GPU):
    pip install -r requirements.txt coremltools
    python -m tools.convert_embedder

Outputs:
    App/Resources/query_embedder.mlpackage     CoreML model (FP16 weights), Neural Engine capable
    App/Resources/vocab.txt                    WordPiece vocabulary for WordPieceTokenizer.swift
    MobiCureVNTests/Fixtures/QueryEmbedderParity.json
"""

from __future__ import annotations

import argparse
import json
import shutil
import tempfile
from pathlib import Path

import numpy as np
import torch

_PIPELINE = Path(__file__).resolve().parent.parent
_REPO = _PIPELINE.parent

MODEL_ID = "BAAI/bge-small-en-v1.5"
# Must equal QueryEmbedder.swift `maxSeqLen` (and WordPieceTokenizer's maxSeqLen).
MAX_SEQ_LEN = 128

# Chosen to exercise every branch of BERT's basic tokenizer that the Swift port has to mirror:
# punctuation splitting, accent stripping, non-ASCII symbols, CJK isolation, whitespace
# variants, and truncation past MAX_SEQ_LEN.
PARITY_TEXTS = [
    "What are the signs that my surgical wound is infected?",
    "Can I shower with a stoma bag?",
    "Café résumé naïve: 38°C fever for 3 days!!",
    "Hà Nội colostomy follow-up",
    "  multiple   spaces\tand\nnewlines  ",
    "stoma-care (post-op) day #3: $50, <tag> a+b=c ~ok | 50% [1, 2]",
    "日本語 and English mixed",
    "What should I eat after a low anterior resection? " * 12,
]


class QueryEncoder(torch.nn.Module):
    """BERT embeddings + encoder with the pooling SentenceTransformer uses, then L2 norm.

    Built from the submodules rather than calling the HF model's forward: transformers 5
    routes attention masks through `masking_utils`, which does not survive `torch.jit.trace`.
    The additive mask uses -1e4 rather than the dtype minimum so FP16 execution on the
    Neural Engine cannot overflow it to -inf.
    """

    def __init__(self, bert: torch.nn.Module, pooling: str):
        super().__init__()
        if pooling not in ("cls", "mean"):
            raise ValueError(f"unsupported pooling mode {pooling!r}")
        self.embeddings = bert.embeddings
        self.encoder = bert.encoder
        self.pooling = pooling

    def forward(
        self, input_ids: torch.Tensor, attention_mask: torch.Tensor
    ) -> torch.Tensor:
        hidden = self.embeddings(
            input_ids=input_ids, token_type_ids=torch.zeros_like(input_ids)
        )
        mask = attention_mask[:, None, None, :].to(hidden.dtype)
        hidden = self.encoder(hidden, attention_mask=(1.0 - mask) * -1e4)[0]
        if self.pooling == "cls":
            pooled = hidden[:, 0]
        else:
            weights = attention_mask.unsqueeze(-1).to(hidden.dtype)
            pooled = (hidden * weights).sum(dim=1) / weights.sum(dim=1).clamp(min=1e-9)
        return torch.nn.functional.normalize(pooled, p=2, dim=1)


def pooling_mode(st_model) -> str:
    try:
        from sentence_transformers.sentence_transformer.modules import Normalize, Pooling
    except ImportError:  # sentence-transformers < 5
        from sentence_transformers.models import Normalize, Pooling

    pooling = [m for m in st_model if isinstance(m, Pooling)]
    if len(pooling) != 1 or not any(isinstance(m, Normalize) for m in st_model):
        raise SystemExit(
            f"{MODEL_ID}: expected Transformer -> Pooling -> Normalize, got {list(st_model)}"
        )
    mode = getattr(pooling[0], "pooling_mode", None)
    if not isinstance(mode, str):  # sentence-transformers < 5
        mode = pooling[0].get_pooling_mode_str()
    return mode


def encode_ids(tokenizer, text: str) -> tuple[torch.Tensor, torch.Tensor]:
    enc = tokenizer(
        text,
        padding="max_length",
        truncation=True,
        max_length=MAX_SEQ_LEN,
        return_tensors="pt",
    )
    return enc["input_ids"], enc["attention_mask"]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", default=MODEL_ID)
    parser.add_argument("--out-dir", type=Path, default=_REPO / "App" / "Resources")
    parser.add_argument(
        "--fixture",
        type=Path,
        default=_REPO / "MobiCureVNTests" / "Fixtures" / "QueryEmbedderParity.json",
    )
    args = parser.parse_args()

    import coremltools as ct
    from sentence_transformers import SentenceTransformer
    from transformers import AutoModel, AutoTokenizer

    print(f"Loading {args.model} ...")
    st_model = SentenceTransformer(args.model, device="cpu")
    st_model.max_seq_length = MAX_SEQ_LEN
    pooling = pooling_mode(st_model)
    tokenizer = AutoTokenizer.from_pretrained(args.model)
    bert = AutoModel.from_pretrained(args.model, attn_implementation="eager").eval()
    encoder = QueryEncoder(bert, pooling).eval()
    print(f"pooling = {pooling}, max_seq_len = {MAX_SEQ_LEN}")

    # ── Parity with what built the index ────────────────────────────────────
    reference = st_model.encode(
        PARITY_TEXTS, normalize_embeddings=True, convert_to_numpy=True
    )
    cases = []
    with torch.no_grad():
        for text, ref in zip(PARITY_TEXTS, reference):
            ids, mask = encode_ids(tokenizer, text)
            ours = encoder(ids, mask)[0].numpy()
            cosine = float(np.dot(ours, ref))
            if cosine < 0.9999:
                raise SystemExit(
                    f"parity failed ({cosine:.6f}) for {text!r}: not converting a model that disagrees with the index"
                )
            cases.append(
                {
                    "text": text,
                    "input_ids": ids[0].tolist(),
                    "attention_mask": mask[0].tolist(),
                    "embedding": [round(float(x), 6) for x in ref],
                }
            )
    print(
        f"parity with SentenceTransformer: {len(cases)}/{len(cases)} texts at cosine >= 0.9999"
    )

    # ── Export and convert ──────────────────────────────────────────────────
    # torch.export rather than torch.jit.trace: tracing records shape arithmetic as aten::Int
    # nodes that coremltools cannot fold on current torch releases. The exported program is
    # checked against the reference before it is converted.
    dummy_ids, dummy_mask = encode_ids(tokenizer, PARITY_TEXTS[0])
    with torch.no_grad():
        exported = torch.export.export(encoder, (dummy_ids, dummy_mask))
        exported_out = exported.module()(*encode_ids(tokenizer, PARITY_TEXTS[2]))[0].numpy()
    if float(np.dot(exported_out, reference[2])) < 0.9999:
        raise SystemExit("exported program diverges from the eager module")

    mlmodel = ct.convert(
        exported.run_decompositions({}),
        inputs=[
            ct.TensorType(name="input_ids", shape=(1, MAX_SEQ_LEN), dtype=np.int32),
            ct.TensorType(name="attention_mask", shape=(1, MAX_SEQ_LEN), dtype=np.int32),
        ],
        # Float32 output explicitly: with FP16 compute the converter otherwise emits a FLOAT16
        # multiarray, which QueryEmbedder.swift does not read -- embed() would return nil and
        # the app would silently fall back to FTS-only.
        outputs=[ct.TensorType(name="embedding", dtype=np.float32)],
        # The torch.export frontend requires iOS 17; the app's deployment target is 18.
        minimum_deployment_target=ct.target.iOS17,
        compute_precision=ct.precision.FLOAT16,
        compute_units=ct.ComputeUnit.CPU_AND_NE,
    )
    mlmodel.short_description = f"{args.model} query encoder ({pooling} pooling, L2-normalised, {MAX_SEQ_LEN} tokens)"

    spec = mlmodel.get_spec().description
    io_types = {
        f.name: ct.proto.FeatureTypes_pb2.ArrayFeatureType.ArrayDataType.Name(f.type.multiArrayType.dataType)
        for f in list(spec.input) + list(spec.output)
    }
    expected = {"input_ids": "INT32", "attention_mask": "INT32", "embedding": "FLOAT32"}
    if io_types != expected:
        raise SystemExit(f"model I/O {io_types} does not match what QueryEmbedder.swift reads: {expected}")

    args.out_dir.mkdir(parents=True, exist_ok=True)
    model_path = args.out_dir / "query_embedder.mlpackage"
    if model_path.exists():
        shutil.rmtree(model_path)
    mlmodel.save(str(model_path))

    with tempfile.TemporaryDirectory() as tmp:
        vocab_file = Path(tokenizer.save_vocabulary(tmp)[0])
        shutil.copyfile(vocab_file, args.out_dir / "vocab.txt")

    args.fixture.parent.mkdir(parents=True, exist_ok=True)
    args.fixture.write_text(
        json.dumps(
            {
                "model": args.model,
                "pooling": pooling,
                "max_seq_len": MAX_SEQ_LEN,
                "min_cosine_on_device": 0.999,
                "cases": cases,
            },
            ensure_ascii=False,
            indent=1,
        )
        + "\n",
        encoding="utf-8",
    )

    size_mb = (
        sum(f.stat().st_size for f in model_path.rglob("*") if f.is_file()) / 1_000_000
    )
    print(
        f"Saved {model_path} ({size_mb:.1f} MB), {args.out_dir / 'vocab.txt'}, {args.fixture}"
    )
    print(
        "Xcode picks both resources up automatically (App/ is a synchronized folder)."
    )
    print("Verify on a device or simulator: MobiCureVNTests/QueryEmbedderParityTests.")


if __name__ == "__main__":
    main()
