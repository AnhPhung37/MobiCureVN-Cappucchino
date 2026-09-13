# Verifying the MLX generation API

_Verified 2026-09-13 against the source of the mlx-swift-lm **3.31.3** tag
(`Libraries/MLXLMCommon/Evaluate.swift`, `KVCache.swift`) — the minimum version the project
pins. Re-verify whenever the pin moves._

`LLMService.swift` applies every generation knob through `MLXLMCommon.GenerateParameters`, a type
from a fast-moving package. This document records what that type actually declares at the pinned
version, the two runtime behaviours the knobs depend on, and what ships.

---

## Pinning

- Both packages are `upToNextMinorVersion` (`mlx-swift` from 0.31.3, `mlx-swift-lm` from 3.31.3):
  patch releases resolve, API-changing minor releases do not.
- **`Package.resolved` must be committed**, and until this branch it could not be: `.gitignore`
  ignored `*.xcodeproj`, which ignores the lockfile inside the project whatever the comment next
  to it said. `.gitignore` now ignores only per-user state inside the project. After the first
  resolve on the Mac:

  ```bash
  xcodebuild -resolvePackageDependencies -project MobiCureVN.xcodeproj
  git check-ignore -v MobiCureVN.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved  # must print nothing
  git add MobiCureVN.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
  ```

## What 3.31.3 declares

| `GenerateParameters` property | Type | Default | How `LLMService` sets it |
|---|---|---|---|
| `maxTokens` | `Int?` | `nil` | always, from the request's `GenerationOptions` |
| `temperature`, `topP` | `Float` | — | always, from `GenerationOptions` |
| `prefillStepSize` | `Int` (`var`) | **512** | only when `InferenceTuning.generation.prefillStepSize` is set |
| `maxKVSize` | `Int?` | `nil` | only when set |
| `kvBits` | `Int?` | `nil` | only when set **and** `maxKVSize` is not |
| `kvGroupSize` | `Int` | 64 | with `kvBits` |
| `quantizedKVStart` | `Int` | 0 | with `kvBits` |

The knobs are assigned as properties after `GenerateParameters(maxTokens:temperature:topP:)`, so
the code depends only on these names existing and being `var`, not on the initializer's argument
order. Later mlx-swift-lm releases move `prefillStepSize` to `prefill.stepSize` and keep a
deprecated alias: moving the pin produces a warning, not a build failure.

Two behaviours the knobs depend on:

1. **`kvBits` quantizes only `KVCacheSimple`** (`maybeQuantizeKVCache`, `KVCache.swift:1779`).
   Setting `maxKVSize` replaces each full-attention cache with a `RotatingKVCache`, which that
   function skips — so with both set the bits do nothing at all. `LLMService.effectiveKVBits` drops
   `kvBits` in that case and logs it, rather than letting the tuning file claim a quantized cache.
   Non-attention layers (Mamba-style caches in hybrid models) are never quantized either.
2. **Every generation ends with `.info(GenerateCompletionInfo)`**, whose public `stopReason` is
   `.stop`, `.length` or `.cancelled`. `LLMService.streamEvents` forwards it as `LLMCompletion`,
   and `MedicalChatOrchestrator` appends a localized "answer was cut off" notice — restoring the
   consult-your-provider disclaimer the cut removed — to any answer that stopped at `.length`.

## What ships

| Knob | Value | Why |
|---|---|---|
| `maxTokens` | **512** (was 1024) | Halves worst-case decode. Vietnamese costs more tokens per idea on several tokenizers, so truncation is checked per language (Docs/Test-Protocol.md §3.6), and a truncated answer is labelled, never silent. |
| `prefillStepSize` | `null` | The runtime default is already 512 — the value this branch first shipped, which therefore changed nothing. Set a lower value (e.g. 256) only to bound prefill memory on a constrained device. |
| `kvBits`, `kvGroupSize`, `quantizedKVStart` | `null` | Changes output. Enable only after the sweep below. |
| `maxKVSize` | `null` | Overwrites old context once reached, and disables `kvBits`. Enable only if a device runs out of memory. |

## The sweep on device

The bundled `App/Resources/InferenceTuning.json` needs a rebuild to change. The no-rebuild knob is
the **Documents** copy: Xcode → Devices and Simulators → the app → Download Container, edit
`AppData/Documents/InferenceTuning.json`, Replace Container, relaunch. An edited file overrides the
bundle key by key; an untouched seed written by an earlier build does not (see
`InferenceTuning.layer`, merged from `final/context-budget-fix`).

Suggested values when enabling: `kvBits: 8`, `kvGroupSize: 64`, `quantizedKVStart: 0`, with
`maxKVSize` left `null`.

```bash
TEST_RUNNER_MOBICURE_BENCH=1 \
TEST_RUNNER_MOBICURE_BENCH_OUT="$PWD/Docs/test-runs/kv-null.json" \
xcodebuild test -scheme MobiCureVN -destination 'platform=iOS,name=<iPad>' \
  -only-testing:MobiCureVNTests/LatencyBenchmarkTests
# repeat with kvBits 8 (kv-8bit.json), then 4 (kv-4bit.json)
```

Record for each run:

- **p95 time-to-final** and **cold start** — from the benchmark JSON (on a device, take it from
  the `.xcresult` attachment).
- **Peak memory** — Instruments → Allocations during a long answer. This is the number `kvBits`
  exists to move; if it does not drop, the setting is not taking effect.
- **Answer quality** — the 30-question sheet from `Docs/BE/Answer-Quality-Rubric.md`. A latency or
  memory win that costs grounding is not a win for this app.

**Keep 8-bit only if quality is unchanged. Keep 4-bit only if a device cannot run 8-bit.**
