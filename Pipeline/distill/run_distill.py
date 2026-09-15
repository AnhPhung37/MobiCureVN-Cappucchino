"""Train, fuse and (optionally) quantize a distilled chat model with mlx-lm.

    python -m distill.run_distill train --student Qwen/Qwen2.5-3B-Instruct \\
        --data distill/data/qwen2_5_3b --adapters distill/adapters/qwen2_5_3b
    python -m distill.run_distill fuse --student Qwen/Qwen2.5-3B-Instruct \\
        --adapters distill/adapters/qwen2_5_3b --out distill/out/qwen2_5_3b-distilled-4bit

`fuse` merges the adapter into the student and, for a full-precision student, quantizes the
result to mlx-community's 4-bit layout (group size 64) so it is a drop-in for the current
download. A student that is already 4-bit (QLoRA) is fused as is. `--dry-run` prints commands on
any machine; running them needs Apple silicon. Docs/BE/LoRA-Distillation.md has the acceptance
checks.
"""

from __future__ import annotations

import argparse
import json
import platform
import shutil
import subprocess
import sys
from importlib import metadata
from pathlib import Path

CONFIG = Path(__file__).with_name("lora_config.yaml")


def train_command(args: argparse.Namespace) -> list[str]:
    command = [
        sys.executable, "-m", "mlx_lm.lora",
        "--config", str(CONFIG),
        "--model", args.student,
        "--data", str(args.data),
        "--adapter-path", str(args.adapters),
    ]
    if args.iters is not None:
        command += ["--iters", str(args.iters)]
    return command


def fuse_commands(args: argparse.Namespace) -> list[list[str]]:
    if args.student_is_quantized:
        return [[sys.executable, "-m", "mlx_lm.fuse", "--model", args.student,
                 "--adapter-path", str(args.adapters), "--save-path", str(args.out)]]
    fused = Path(str(args.out) + "-fused-fp")
    return [
        [sys.executable, "-m", "mlx_lm.fuse", "--model", args.student,
         "--adapter-path", str(args.adapters), "--save-path", str(fused)],
        [sys.executable, "-m", "mlx_lm.convert", "--hf-path", str(fused), "--mlx-path", str(args.out),
         "--quantize", "--q-bits", "4", "--q-group-size", "64"],
    ]


def _require_data(data: Path) -> None:
    for name in ("train.jsonl", "valid.jsonl"):
        if not (data / name).exists():
            raise SystemExit(f"{data / name} not found — run python -m distill.build_distill_dataset first")


def main() -> None:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="step", required=True)
    train = sub.add_parser("train")
    train.add_argument("--student", required=True)
    train.add_argument("--data", type=Path, required=True)
    train.add_argument("--adapters", type=Path, required=True)
    train.add_argument("--iters", type=int, default=None)
    fuse = sub.add_parser("fuse")
    fuse.add_argument("--student", required=True)
    fuse.add_argument("--adapters", type=Path, required=True)
    fuse.add_argument("--out", type=Path, required=True)
    fuse.add_argument("--student-is-quantized", action="store_true")
    for p in (train, fuse):
        p.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    if args.step == "train":
        _require_data(args.data)
        commands = [train_command(args)]
    else:
        commands = fuse_commands(args)
    for command in commands:
        print(" ".join(command))
    if args.dry_run:
        return
    if sys.platform != "darwin" or platform.machine() != "arm64":
        raise SystemExit("mlx-lm needs Apple silicon; use --dry-run elsewhere")
    for command in commands:
        subprocess.run(command, check=True)

    if args.step == "fuse":
        if not args.student_is_quantized:
            shutil.rmtree(Path(str(args.out) + "-fused-fp"), ignore_errors=True)
        adapter_config = args.adapters / "adapter_config.json"
        provenance = {
            "student": args.student,
            "student_is_quantized": args.student_is_quantized,
            "adapters": str(args.adapters),
            "adapter_config": json.loads(adapter_config.read_text()) if adapter_config.exists() else None,
            "mlx_lm_version": metadata.version("mlx-lm"),
            "commands": commands,
        }
        (args.out / "distill_provenance.json").write_text(json.dumps(provenance, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
