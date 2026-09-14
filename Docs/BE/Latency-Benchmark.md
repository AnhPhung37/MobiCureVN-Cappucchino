# Latency Benchmark — success criterion #3

> "Response generation time should be under 5 seconds for text-based queries when
> running on the provided Mac Studio or iPad."

Until this harness existed the repo held **no latency measurement at all** — only
qualitative notes (`Docs/model-audit.md:24`). This document is the procedure that
turns criterion #3 into a number you can defend.

---

## What is measured

`MobiCureVNTests/LatencyBenchmarkTests.swift` drives the **full production pipeline**
(`MedicalChatOrchestrator.processQuery`), not the raw model. That matters: the criterion
is about what a patient waits for, which includes input guardrail, emergency detection,
RAG retrieval, prompt assembly, decode, output guardrail, and the language-drift check.

Per query it records:

| Field | Meaning |
|---|---|
| `timeToFirstPreview` | until the first `.preview` — when the bubble stops being empty |
| `timeToFinal` | until the guardrail-validated `.final` — **this is criterion #3** |
| `previewEventCount` | how many draft snapshots reached the UI |
| `answerCharacters` | answer length, so slow/long can be told apart from slow/short |

Reported separately, never folded into the summary:

- `modelLoadSeconds` — weight load, once per launch.
- `coldStartSeconds` — first generation after load (lazy paging + Metal pipeline
  compilation). Excluding it entirely would flatter the app; averaging it in would
  misrepresent the steady state. It gets its own line.

The summary reports **p95**, not just the mean — an average that one fast query can
carry does not answer a question about what users experience.

## Query set

10 queries, fixed and committed: 5 English + 5 Vietnamese, spread across short /
medium / long expected answers. Decode time scales with answer length, so a set of
short questions would produce a number that says nothing about real use.

The set runs **3 times** by default (`MOBICURE_BENCH_REPEATS`), for 30 samples. Percentiles are
nearest-rank: p95 over 30 samples is the second-slowest turn. Over a single pass of 10 it would
simply be the slowest one, which is why one pass is not enough to report a p95.

## How to run

> **`xcodebuild` does not forward ordinary environment variables into the test process on a
> device.** Prefix them with `TEST_RUNNER_` — `xcodebuild` strips the prefix and passes them
> through, so the test still reads `MOBICURE_BENCH`. Without the prefix the benchmark reports
> **skipped**. Setting the variables in the scheme's Test action works too.
>
> The model must already be **downloaded on the device** (use the in-app model picker). The
> test resolves its local path through `ModelManager`; a model that is not on disk skips with a
> message saying so.

The benchmark is **opt-in**. It loads a multi-GB model and takes minutes, so it is
skipped unless `MOBICURE_BENCH=1` — normal `⌘U` and CI runs are unaffected.

### iPad M5 (primary target)

```bash
mkdir -p Docs/benchmarks
TEST_RUNNER_MOBICURE_BENCH=1 \
TEST_RUNNER_MOBICURE_BENCH_OUT="$PWD/Docs/benchmarks/latency-ipad-m5.json" \
xcodebuild test \
  -scheme MobiCureVN \
  -destination 'platform=iOS,name=<your iPad name>' \
  -only-testing:MobiCureVNTests/LatencyBenchmarkTests
```

On a physical device the process sandbox cannot write into the repo, so the report is
**also attached to the test result**. Open the `.xcresult` in Xcode →  Report navigator →
the `latency-benchmark.json` attachment, and save it into `Docs/benchmarks/`.

### Mac Studio M3 Max

```bash
TEST_RUNNER_MOBICURE_BENCH=1 \
TEST_RUNNER_MOBICURE_BENCH_OUT="$PWD/Docs/benchmarks/latency-macstudio-m3max.json" \
xcodebuild test \
  -scheme MobiCureVN \
  -destination 'platform=macOS,arch=arm64,variant=Designed for iPad' \
  -only-testing:MobiCureVNTests/LatencyBenchmarkTests
```

### Comparing models

```bash
TEST_RUNNER_MOBICURE_BENCH_MODEL="mlx-community/Qwen2.5-3B-Instruct-4bit" ...
```

Defaults to `ModelCatalog.default` (Qwen 3.5 4B) — benchmark the model you actually ship.

## Reporting rules

1. **Run on both devices.** The criterion names Mac Studio *or* iPad; a number from the
   simulator is not a number from either. The simulator has no Metal-backed MLX path
   worth measuring — do not report it.
2. **Commit the JSON** into `Docs/benchmarks/`. The test writes `device`, `osVersion`,
   `model` and `generatedAt` into every report so a reader can tell two runs apart.
3. **Report p95 and max, not just the mean.** If p95 exceeds 5s, say so and state why —
   a missed criterion reported honestly costs less than a criterion quietly dropped.
4. **Quote cold start separately.** "First answer after launch: Xs; steady state p95: Ys"
   is the truthful shape of this system's latency.
5. Re-run after any change to the model, generation options, or the number of LLM passes
   in the orchestrator. Those are the three things that move this number.

## If p95 misses the budget

Known levers, cheapest first — all are already identified in the codebase:

- **Gate the second LLM pass.** The orchestrator makes auxiliary LLM calls (fact
  extraction, profile-update extraction) per turn. Gating them behind a cheap
  precondition removes a full decode from the critical path.
- **Cut `InferenceTuning.generation.maxTokens`.** `GenerationOptions.answer` reads it; decode time
  is linear in tokens emitted. Check truncated answers per language when lowering it.
- **Ship a smaller model.** `gemma3_1B` / `qwen2_5_3B` are already in `ModelCatalog`.
  Benchmark them with `MOBICURE_BENCH_MODEL` before deciding — this is exactly the
  accuracy-vs-latency trade-off the report should discuss.
- **Report `timeToFirstPreview` as the felt latency.** The preview stream already puts
  text on screen well before `.final`. That is a legitimate mitigation to describe, but
  it does **not** replace the `.final` number for criterion #3.
