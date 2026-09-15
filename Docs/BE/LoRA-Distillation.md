# LoRA distillation of the chat model

Branch `final0.1-lora-distill`, built on `final0.1-dwq` (it reuses that branch's app-prompt
builder, so merge `final0.1-dwq` first). Tooling to fine-tune an on-device chat model on a larger
teacher's answers to the app's own prompts. Nothing in the app changes here: the output is a
fused 4-bit model to evaluate, then add to `ModelCatalog`.

## Why

The on-device model answers from the same retrieved passages a larger model would, but it
follows the prompt's rules less reliably: grounding in the passages, citing them, keeping advice
conditional on what the patient actually said, the consult-your-provider disclaimer, and staying
in Vietnamese. Distillation teaches the small model this task's register from examples, instead
of general chat. It does not add medical knowledge the passages do not carry, and it is not a
substitute for retrieval.

## Data: `distill/build_distill_dataset.py`

Rows are the DWQ calibration rows (`Docs/BE/DWQ-Quantization.md`): the orchestrator's stable
prefix parsed from Swift, hybrid-retrieved context packed to the app budget, section-heading
questions that exclude the golden set. Here a teacher answer is required, and then filtered:

| Rejected when | Why |
|---|---|
| no answer, or `<think>` left in | nothing to learn, or reasoning the app never shows |
| Vietnamese-letter word share < 0.25 under a Vietnamese directive, or > 0.02 under an English one | training on drift teaches the drift the guardrails exist to catch |
| over 512 tokens (at 1.75 tokens/word) | the device cuts the answer at `maxTokens`; the student would learn answers that lose their disclaimer |

The default mix is 50% Vietnamese directives (the calibration builder defaults to 30%): the
Vietnamese path is the weaker one and the one this project exists for. Rows split 90/5/5 into
`train/valid/test.jsonl` by a hash of the question, so adding questions never moves an existing
one between splits. The rejection counts go into `<out>/README.md`; a high `wrong_language` count
means the teacher is the wrong teacher.

**Choosing the teacher.** Any model behind an OpenAI-compatible endpoint. Only corpus passages and
synthetic questions are sent — no patient data — so a hosted model is acceptable on privacy
grounds; check its terms, since some providers forbid training other models on outputs. A local
option on a Mac Studio is `mlx_lm.server` with a large open model.

## Training: `distill/lora_config.yaml`, `distill/run_distill.py`

```bash
cd Pipeline
python -m eval.build_indexes
python -m distill.build_distill_dataset --out distill/data/qwen2_5_3b \
    --teacher-base-url http://127.0.0.1:8080 --teacher-model <teacher>
python -m distill.run_distill train --student Qwen/Qwen2.5-3B-Instruct \
    --data distill/data/qwen2_5_3b --adapters distill/adapters/qwen2_5_3b
python -m distill.run_distill fuse --student Qwen/Qwen2.5-3B-Instruct \
    --adapters distill/adapters/qwen2_5_3b --out distill/out/qwen2_5_3b-distilled-4bit
```

- `mask_prompt: true` — loss on the assistant turn only; the system prompt and passages are
  inputs the app supplies anyway.
- `max_seq_length: 4096` — system prompt + 3000 tokens of context + a 512-token answer; mlx-lm's
  2048 default would train on answers whose context was cut off.
- Rank 16, scale 20, dropout 0.05, 16 layers, batch 1 × 8 accumulation, lr 1e-5, 1000 iterations,
  gradient checkpointing, validation every 100 steps on the whole `valid.jsonl`.
- `fuse` merges the adapter and quantizes to 4 bits, group size 64 — mlx-community's layout, so
  the result drops in for the current download. `--student-is-quantized` fuses a QLoRA run as is.
  `distill_provenance.json` records the student, adapter config, mlx-lm version and commands.
- `--dry-run` prints every command on any machine; running needs Apple silicon.

**Text-only students only**, for the reason in `Docs/BE/DWQ-Quantization.md`: mlx-lm's text model
classes drop vision weights, so a fused Qwen 3.5 4B would not load as the vision model the catalog
routes through `VLMModelFactory`. Targets: Qwen 2.5 3B, Llama 3.2 3B, Gemma 3 1B.

## Accepting a distilled model

Fine-tuning can erode behaviour the prompt enforces, so the acceptance bar is safety first:

1. **Adversarial script** (`Docs/BE/Adversarial-Chat-Test-Script.md`) on the distilled model and
   the base student. Any new failure rejects the model, whatever else improved.
2. **Answer quality** on the golden set (excluded from training) with
   `Docs/BE/Answer-Quality-Rubric.md`, against the base student and the stock 4-bit model.
3. **Held-out loss**: `mlx_lm.lora --test` on `test.jsonl` — lower than the base student's, or the
   adapter learned nothing that generalizes.
4. **Latency** on the device: unchanged (same architecture, bits and group size).
5. Ship by adding a `ModelCatalog` case; the tokenizer is unchanged, so the base model's
   `wordsToTokensRatio` applies.

## Tests

`python -m unittest eval.tests.test_distill_dataset` (8): language and length filters, rejection
counts, stable hash splits, and the train/fuse commands. No MLX needed.
