"""Run mlx-lm's DWQ on the app-shaped calibration set, and record what produced the weights.

    python -m quant.run_dwq --teacher Qwen/Qwen2.5-3B-Instruct \\
        --data quant/data/qwen2_5_3b --mlx-path quant/out/qwen2_5_3b-dwq-4bit
    python -m quant.run_dwq ... --dry-run          # print the mlx_lm.dwq command only

Apple silicon only (MLX). The quantized model lands in --mlx-path with dwq_provenance.json next
to its weights. Docs/BE/DWQ-Quantization.md covers choosing the teacher and checking the result.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import platform
import subprocess
import sys
from importlib import metadata
from pathlib import Path

# mlx_lm.dwq draws its validation rows from the same file, right after the training rows.
VALID_SAMPLES = 32


def calibration_rows(data_dir: Path) -> int:
    train = data_dir / "train.jsonl"
    if not train.exists():
        raise SystemExit(f"{train} not found — run python -m quant.build_dwq_calibration first")
    return sum(1 for line in train.read_text(encoding="utf-8").splitlines() if line.strip())


def num_samples_for(rows: int, requested: int | None) -> int:
    """Training rows that leave VALID_SAMPLES for validation; mlx_lm would silently train on fewer."""
    available = rows - VALID_SAMPLES
    if available < 32:
        raise SystemExit(f"{rows} calibration rows is too few: DWQ needs at least {32 + VALID_SAMPLES}")
    if requested is not None and requested > available:
        raise SystemExit(f"--num-samples {requested} exceeds the {available} rows left after validation")
    return requested if requested is not None else min(available, 2048)


def dwq_command(args: argparse.Namespace, num_samples: int) -> list[str]:
    command = [
        sys.executable, "-m", "mlx_lm.dwq",
        "--model", args.teacher,
        "--mlx-path", str(args.mlx_path),
        "--data-path", str(args.data),
        "--bits", str(args.bits),
        "--group-size", str(args.group_size),
        "--num-samples", str(num_samples),
        # The app's system prompt plus 3000 tokens of context and a 512-token answer: the
        # default 1025 would calibrate on the persona and cut every retrieved passage off.
        "--max-seq-length", str(args.max_seq_length),
        "--batch-size", str(args.batch_size),
        "--learning-rate", str(args.learning_rate),
        "--seed", str(args.seed),
    ]
    if args.quantized_model:
        command += ["--quantized-model", args.quantized_model]
    if args.grad_checkpoint:
        command.append("--grad-checkpoint")
    return command


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--teacher", required=True, help="full-precision model (HF repo or path)")
    parser.add_argument("--quantized-model", default=None, help="start from an existing quantization")
    parser.add_argument("--data", type=Path, required=True)
    parser.add_argument("--mlx-path", type=Path, required=True)
    parser.add_argument("--bits", type=int, default=4)
    # mlx-community's 4-bit chat models use group size 64; keep it so the DWQ result is a drop-in.
    parser.add_argument("--group-size", type=int, default=64)
    parser.add_argument("--num-samples", type=int, default=None)
    parser.add_argument("--max-seq-length", type=int, default=4096)
    parser.add_argument("--batch-size", type=int, default=1)
    parser.add_argument("--learning-rate", type=float, default=1e-6)
    parser.add_argument("--seed", type=int, default=123)
    parser.add_argument("--no-grad-checkpoint", dest="grad_checkpoint", action="store_false")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    num_samples = num_samples_for(calibration_rows(args.data), args.num_samples)
    command = dwq_command(args, num_samples)
    print(" ".join(command))
    if args.dry_run:
        return
    if sys.platform != "darwin" or platform.machine() != "arm64":
        raise SystemExit("mlx_lm.dwq needs Apple silicon; use --dry-run elsewhere")

    subprocess.run(command, check=True)

    train = args.data / "train.jsonl"
    provenance = {
        "teacher": args.teacher,
        "quantized_model": args.quantized_model,
        "bits": args.bits,
        "group_size": args.group_size,
        "num_samples": num_samples,
        "max_seq_length": args.max_seq_length,
        "learning_rate": args.learning_rate,
        "batch_size": args.batch_size,
        "seed": args.seed,
        "calibration_train_sha256": hashlib.sha256(train.read_bytes()).hexdigest(),
        "mlx_lm_version": metadata.version("mlx-lm"),
        "command": command,
    }
    (args.mlx_path / "dwq_provenance.json").write_text(json.dumps(provenance, indent=2) + "\n", encoding="utf-8")
    print(f"Wrote {args.mlx_path / 'dwq_provenance.json'}")


if __name__ == "__main__":
    main()
