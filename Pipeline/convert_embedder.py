"""
convert_embedder.py

Converts BAAI/bge-small-en-v1.5 to a CoreML package for on-device query embedding.
The output model + vocab must match build_index.py's EMBED_MODEL exactly.

Run from Pipeline/:
    pip install coremltools torch transformers
    python convert_embedder.py

Outputs (drag both into Xcode, add to app target):
    query_embedder.mlpackage   ~90 MB — CoreML model, uses Neural Engine on device
    vocab.txt                  ~230 KB — WordPiece vocabulary for Swift tokenizer
"""

from pathlib import Path
import numpy as np
import torch
import coremltools as ct
from transformers import AutoTokenizer, AutoModel

MODEL_ID = "BAAI/bge-small-en-v1.5"
MAX_SEQ_LEN = 128
OUTPUT_MODEL = Path("query_embedder.mlpackage")
OUTPUT_VOCAB = Path("vocab.txt")


class BGEEmbedder(torch.nn.Module):
    """Wraps the HuggingFace model with mean pooling + L2 norm — matches build_index.py."""

    def __init__(self, model: torch.nn.Module):
        super().__init__()
        self.model = model

    def forward(self, input_ids: torch.Tensor, attention_mask: torch.Tensor) -> torch.Tensor:
        outputs = self.model(input_ids=input_ids, attention_mask=attention_mask)
        token_embeddings = outputs.last_hidden_state
        mask_expanded = attention_mask.unsqueeze(-1).expand(token_embeddings.size()).float()
        summed = torch.sum(token_embeddings * mask_expanded, dim=1)
        counts = torch.clamp(mask_expanded.sum(dim=1), min=1e-9)
        embedding = summed / counts
        return torch.nn.functional.normalize(embedding, p=2, dim=1)


def main() -> None:
    print(f"Loading {MODEL_ID}...")
    tokenizer = AutoTokenizer.from_pretrained(MODEL_ID)
    hf_model = AutoModel.from_pretrained(MODEL_ID, torchscript=True)
    hf_model.eval()

    wrapper = BGEEmbedder(hf_model)

    # Export vocab.txt — Swift WordPieceTokenizer reads this directly
    vocab_path = tokenizer.save_vocabulary(".")[0]
    if Path(vocab_path).name != OUTPUT_VOCAB.name:
        Path(vocab_path).rename(OUTPUT_VOCAB)
    print(f"Vocab saved → {OUTPUT_VOCAB}  ({OUTPUT_VOCAB.stat().st_size // 1024} KB)")

    # Trace the model with dummy token arrays
    dummy_ids  = torch.ones(1, MAX_SEQ_LEN, dtype=torch.long)
    dummy_mask = torch.ones(1, MAX_SEQ_LEN, dtype=torch.long)

    with torch.no_grad():
        traced = torch.jit.trace(wrapper, (dummy_ids, dummy_mask))

    # Sanity-check: traced output should be 384-dim unit vector
    with torch.no_grad():
        out = traced(dummy_ids, dummy_mask)
    assert out.shape == (1, 384), f"Unexpected shape: {out.shape}"
    assert abs(float(torch.norm(out)) - 1.0) < 1e-4, "Output is not L2-normalised"
    print("Trace sanity-check passed (shape=384, unit-norm)")

    print("Converting to CoreML (this takes ~1–2 min)...")
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="input_ids",      shape=(1, MAX_SEQ_LEN), dtype=np.int32),
            ct.TensorType(name="attention_mask",  shape=(1, MAX_SEQ_LEN), dtype=np.int32),
        ],
        outputs=[ct.TensorType(name="embedding")],
        minimum_deployment_target=ct.target.iOS16,
        compute_units=ct.ComputeUnits.CPU_AND_NE,  # Neural Engine on A12+
    )

    if OUTPUT_MODEL.exists():
        import shutil
        shutil.rmtree(OUTPUT_MODEL)

    mlmodel.save(str(OUTPUT_MODEL))
    size_mb = sum(f.stat().st_size for f in OUTPUT_MODEL.rglob("*") if f.is_file()) / 1_000_000
    print(f"Saved {OUTPUT_MODEL}  ({size_mb:.1f} MB)")
    print()
    print("Next steps:")
    print("  1. In Xcode → drag query_embedder.mlpackage into the project (✓ add to target)")
    print("  2. In Xcode → drag vocab.txt into the project (✓ add to target)")
    print("  3. Vector search in SQLiteRetriever will activate automatically on next run")


if __name__ == "__main__":
    main()
