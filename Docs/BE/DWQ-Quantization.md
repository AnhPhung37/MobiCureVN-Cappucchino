# DWQ quantization of the chat model

Branch `final0.1-dwq`. Tooling to re-quantize an on-device chat model with mlx-lm's DWQ
(distilled weight quantization), calibrated on prompts shaped like the app's. Nothing in the app
changes on this branch: the output is a model directory to evaluate, then add to `ModelCatalog`.

## What DWQ does, and why the calibration set matters

`mlx_lm.dwq` quantizes a model (or starts from an existing quantization) and then trains only the
quantization scales and biases so the student's next-token distribution matches the
full-precision teacher's on a calibration set. mlx-community's DWQ uploads recover a large part of
the gap between plain 4-bit and full precision at the same size and speed.

The default calibration set is generic chat. This app's turns are not: a system prompt of persona
and safety constraints, ~1,700 words of retrieved English colorectal-care passages, and an answer
in English or Vietnamese. `quant/build_dwq_calibration.py` builds that shape:

| Part | Source |
|---|---|
| Stable prefix | Parsed from `MedicalChatOrchestrator.swift` (`invariantSystemPrompt`, `languageInstruction`, `contextLanguageNote`), so it cannot drift from the app |
| Retrieved context | The eval harness's hybrid retriever over the app index, top 10, packed to 3000 tokens at 1.75 tokens/word, formatted as `formatContextChunks` |
| User turn | A templated question per corpus section heading, in English (ChatService translates before the orchestrator) |
| Assistant turn | Optional teacher answer via an OpenAI-compatible server, `<think>` blocks stripped |
| Language mix | 30% Vietnamese answer directive by default (`--vietnamese-fraction`) |

Golden-set questions (EN and VI, including `en_equivalent`) are excluded, and `--extra-questions`
rows matching them are dropped: calibrating on the evaluation questions would flatter the
quantized model's answer-quality scores. Known approximations — sources listed by document id,
a fixed confidence line, whole-chunk packing — change a few tokens per prompt, not its shape.

## Run it (Mac Studio; MLX needs Apple silicon)

```bash
cd Pipeline
python -m eval.build_indexes                      # the app index the builder retrieves from

# optional: teacher answers, so answer positions are calibrated too
mlx_lm.server --model Qwen/Qwen2.5-3B-Instruct --port 8080 &

python -m quant.build_dwq_calibration --out quant/data/qwen2_5_3b \
    --teacher-base-url http://127.0.0.1:8080 --teacher-model Qwen/Qwen2.5-3B-Instruct

python -m quant.run_dwq --teacher Qwen/Qwen2.5-3B-Instruct \
    --data quant/data/qwen2_5_3b --mlx-path quant/out/qwen2_5_3b-dwq-4bit
```

`run_dwq` defaults: 4 bits, group size 64 (mlx-community's 4-bit layout, so the result is a drop-in
for the current download), `--max-seq-length 4096` (mlx-lm's default 1025 would cut every prompt
off inside the retrieved context), batch 1 with gradient checkpointing, and every row but 32 used
for training — mlx-lm takes its 32 validation rows from the same file and silently trains on fewer
rows when asked for more than exist, so the runner refuses instead. It writes
`dwq_provenance.json` (teacher, settings, calibration sha256, mlx-lm version, command) next to
the weights. `--dry-run` prints the command on any machine.

## Which models this can target today

`mlx_lm` loads models through its text-model classes, and those drop vision weights
(`mlx_lm/models/qwen3_5.py` `sanitize` skips `vision_tower` / `model.visual`). A DWQ run on
Qwen 3.5 4B, MedGemma or Gemma 4 therefore produces a text-only checkpoint, while
`LLMService.visionModelTypes` routes those `model_type`s through `VLMModelFactory` — the result
would not load as the vision model the catalog expects. Until vision weights are grafted back
(not implemented or verified here), target the text-only catalog models:

- `Qwen/Qwen2.5-3B-Instruct` → replaces `mlx-community/Qwen2.5-3B-Instruct-4bit`
- `meta-llama/Llama-3.2-3B-Instruct` → replaces `mlx-community/Llama-3.2-3B-Instruct-4bit`
- `google/gemma-3-1b-it` → replaces `mlx-community/gemma-3-1b-it-4bit`

## Accepting a DWQ model

1. mlx-lm prints validation KL before and after; it warns when the tuned model is worse. A worse
   result is discarded, not shipped.
2. Answer quality on the golden set against the stock 4-bit model, scored with
   `Docs/BE/Answer-Quality-Rubric.md` — the calibration excluded these questions, so the
   comparison is fair.
3. Latency on the device (`Docs/BE/Latency-Benchmark.md`): same bits and group size should mean the
   same speed; a regression means the layout changed.
4. Ship by adding a `ModelCatalog` case pointing at the uploaded repo. The tokenizer is unchanged,
   so the base model's `wordsToTokensRatio` applies.

## Tests

`python -m unittest eval.tests.test_dwq_calibration` (11): Swift literal parsing, the prompt read
verbatim from the orchestrator, the exact EN/VI prompt shape, packing, golden exclusion,
reproducible records with a fake retriever and teacher, and the runner's command and sample
guard. No MLX needed.
