# Verifying the MLX generation API

`LLMService.swift` has pointed at this document for a while; it did not exist, which is
why the KV-cache and prefill knobs sat unwired in `InferenceTuning` with `null` values
and no way for anyone to finish the job. This is that document.

---

## Why it is needed

`MLXLMCommon.GenerateParameters` is the type the whole tuning surface depends on, and it
comes from a **0.x / fast-moving** package. Two things made that unsafe:

1. **The packages were effectively unpinned.** Both used `upToNextMajorVersion`:
   - `mlx-swift` from `0.31.3` → resolved anything `>=0.31.3 <1.0.0`. For a 0.x library
     that is not a compatibility guarantee at all; breaking changes land in *minor* bumps.
   - `mlx-swift-lm` from `3.31.3` → anything `>=3.31.3 <4.0.0`.

   Both are now `upToNextMinorVersion`, so a resolve can pick up patch fixes but cannot
   silently change the API under the app.

2. **`Package.resolved` is not committed.** `.gitignore:14` says, in as many words, that
   it is *intentionally not ignored* — but the file is absent from the tree. Until it is
   committed, two machines can resolve two different versions and only one of them
   compiles. **Commit it after the first resolve on the Mac.**

## How to verify, in five minutes

```bash
# 1. Resolve and pin.
xcodebuild -resolvePackageDependencies -project MobiCureVN.xcodeproj
git add MobiCureVN.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
git commit -m "chore: pin MLX package versions"

# 2. Read the actual declaration for the version you just resolved.
find ~/Library/Developer/Xcode/DerivedData -path '*mlx-swift-lm*' -name 'GenerateParameters.swift' \
  -o -path '*SourcePackages*mlx-swift-lm*' -name '*.swift' | xargs grep -l "struct GenerateParameters"
```

Or simply ⌘-click `GenerateParameters` in `LLMService.swift` and read the definition.

## What the code assumes

`LLMService.swift` applies the knobs as **property assignments after construction**, not
through the memberwise initializer:

```swift
var params = GenerateParameters(maxTokens:temperature:topP:)
if let prefillStepSize = generation.prefillStepSize { params.prefillStepSize = prefillStepSize }
if let kvBits = generation.kvBits { params.kvBits = kvBits; ... }
if let maxKVSize = generation.maxKVSize { params.maxKVSize = maxKVSize }
```

That is deliberate. It depends only on:

- the property **names** existing: `prefillStepSize`, `kvBits`, `kvGroupSize`,
  `quantizedKVStart`, `maxKVSize`;
- those properties being `var` (settable);
- the three-argument init `(maxTokens:temperature:topP:)` remaining valid.

It does **not** depend on the initializer's full argument list or their order, which is the
part most likely to change between releases. If a name has moved, the build fails loudly at
that line — which is the intended failure mode. Fix the name, and update the matching field
in `InferenceTuning.Generation` and `App/Resources/InferenceTuning.json` so the three stay
in step.

### Type check

`InferenceTuning.Generation` declares all five as `Int?`. If the resolved API types any of
them differently (e.g. `kvGroupSize` as non-optional `Int` with a default), the assignment
still compiles — the optional is unwrapped before it is assigned. Only a *name* change or a
`let` property breaks the build.

## What ships on, and what does not

| Knob | Shipped value | Why |
|---|---|---|
| `prefillStepSize` | **512** | Bounds peak memory during prefill by chunking the prompt. Cannot change the tokens produced, only how they are computed — safe to enable without a quality sweep. |
| `maxTokens` | **512** (was 1024) | Decode time is linear in tokens emitted. A patient answer rarely needs 1024; this halves the worst case. Live knob — raise it if answers start getting cut off. |
| `kvBits` | `null` | Quantizing the KV cache cuts its memory 2x at 8 bits and 4x at 4 bits, but it **does** change output. Not enabled without measurement. |
| `kvGroupSize` | `null` | Only meaningful alongside `kvBits`. |
| `quantizedKVStart` | `null` | Only meaningful alongside `kvBits`. |
| `maxKVSize` | `null` | A hard ceiling truncates context once reached, trading conversational continuity for a memory bound. Enable only if a device is actually running out. |

The pattern throughout: **an unset knob leaves the runtime's own default untouched.** Nothing
in this change alters behaviour unless the JSON asks for it, except `maxTokens`.

## The sweep to run on device

`kvBits` is the largest remaining memory lever and the reason this plumbing exists. Run it
with the latency harness, on the real device, and record all three axes together:

```bash
# Baseline, then 8-bit, then 4-bit. Edit App/Resources/InferenceTuning.json between runs —
# no rebuild needed, that is the point of the knob being live.
MOBICURE_BENCH=1 MOBICURE_BENCH_OUT="$PWD/Docs/benchmarks/kv-null.json"  xcodebuild test ...
MOBICURE_BENCH=1 MOBICURE_BENCH_OUT="$PWD/Docs/benchmarks/kv-8bit.json"  xcodebuild test ...
MOBICURE_BENCH=1 MOBICURE_BENCH_OUT="$PWD/Docs/benchmarks/kv-4bit.json"  xcodebuild test ...
```

Suggested starting values when enabling: `kvBits: 8`, `kvGroupSize: 64`,
`quantizedKVStart: 0`.

Record for each run:

- **p95 time-to-final** and **cold start** — from the benchmark JSON.
- **Peak memory** — Instruments → Allocations, or Xcode's memory gauge during a long turn.
  This is the number `kvBits` exists to move; if it does not drop, the knob is not taking
  effect and the wiring is wrong.
- **Answer quality** — the same 30-question sheet from
  `Docs/BE/Answer-Quality-Rubric.md`. 4-bit KV in particular can degrade long answers, and
  a latency win that costs grounding is not a win for this app.

**Keep 8-bit only if quality is unchanged. Keep 4-bit only if a device genuinely cannot run
8-bit.** Do not enable either on latency evidence alone.
