# Model catalog candidates: MedGemma 1.5 4B and Gemma 4 E2B

Branch `final0.1-model-catalog`. Two on-device models added to `ModelCatalog`, and the wound-photo
pre-step moved to the medical one. The default chat model is unchanged (`qwen3_5_4B`), so no
existing install downloads anything new.

## What changed

| File | Change |
|---|---|
| `App/Backend/Configs/ModelCatalog.swift` | `medgemma1_5_4B`, `gemma4_E2B`: ratio, vision flag, size, names |
| `App/Backend/Services/WoundAnalysis/WoundAnalysisService.swift` | `woundVLM` → `.medgemma1_5_4B` |
| `MobiCureVNTests/ModelCatalogCandidatesTests.swift` | pins the measured values and the unchanged default |

## Why these two

- **MedGemma 1.5 4B** (`mlx-community/medgemma-1.5-4b-it-4bit`): Gemma 3 4B whose vision encoder
  and text model were further trained on medical data, including dermatology photos — the closest
  public match to stoma/wound photos and patient-education questions at a size the iPad holds.
- **Gemma 4 E2B** (`mlx-community/gemma-4-e2b-it-4bit`): ~2B effective parameters with a vision
  tower; the small-footprint comparison point against Qwen 3.5 4B for time-to-first-token.

## Measured and checked on this branch

| | MedGemma 1.5 4B | Gemma 4 E2B | Qwen 3.5 4B (reference) |
|---|---|---|---|
| `config.json` `model_type` | `gemma3` (+ `vision_config`) | `gemma4` (+ `vision_config`) | `qwen3_5` |
| Loads through | VLMModelFactory | VLMModelFactory | VLMModelFactory |
| 4-bit safetensors | 3.40 GB | 3.55 GB | ~2.4 GB |
| Tokens/word, EN formatted (1876 chunks) | 1.693 | 1.693 | 1.719 |
| Tokens/word, VI (24 texts) | 1.204 | 1.204 | 1.114 |
| `wordsToTokensRatio` | 1.70 | 1.70 | 1.75 |

- Both `model_type` values are already in `LLMService.visionModelTypes`, so `supportsVision = true`
  matches how the model is actually loaded.
- The ratios are identical because both use the Gemma vocabulary; reproduce with
  `python -m tools.measure_token_ratio --models mlx-community/medgemma-1.5-4b-it-4bit mlx-community/gemma-4-e2b-it-4bit --vi eval/data/queries_vi.jsonl eval/data/answer_quality/reference_answers.md`.
- Gemma 4 E2B is not smaller on disk than a 4B model: its per-layer embeddings dominate the file
  even at 4 bits. Its advantage, if any, is compute per token, which only the device measures.

## Licences

- **MedGemma**: Health AI Developer Foundations terms of use. The upstream repo
  (`google/medgemma-1.5-4b-it`) is gated; the MLX conversion is not, but it is a derivative and the
  same terms apply. It is a developer model, not a validated clinical device — the app's guardrails
  and "not medical advice" framing still carry that responsibility.
- **Gemma 4 E2B**: upstream `google/gemma-4-E2B-it` is tagged Apache-2.0; the MLX card is tagged
  `gemma`. The upstream licence governs; re-check both cards before any distribution.

## Not verified here (needs the Mac/iPad)

No Swift was compiled on this branch's machine. Before merging:

1. Run `ModelCatalogCandidatesTests` and `ContextBudgetTests` (the per-model ratio test iterates
   `ModelCatalog.allCases`).
2. Pick each model in the top-bar picker, download, and ask two golden-set questions (one EN, one
   VI). Check: answer language, sources shown, no truncation notice at `maxTokens` 512.
3. MedGemma's Gemma 3 chat template has no system role and folds the system prompt into the first
   user turn; confirm the answer still follows the prompt's rules (disclaimer, citations).
4. Record TTFT/decode with `Docs/BE/Latency-Benchmark.md` for Gemma 4 E2B vs Qwen 3.5 4B.
5. Wound flow with a text model resident: attach a stoma photo and confirm the findings contain all
   seven `KEY: value` lines (`WoundFindingsParser` fills a log entry). If lines are missing or
   reordered, set `woundVLM` back to `.qwen2_5_VL_3B`.
6. Watch memory during the wound flow's unload → MedGemma → reload sequence
   (`Docs/BE/OOM-Memory-Management.md`); MedGemma is ~1.2 GB larger than Qwen 2.5 VL 3B.
