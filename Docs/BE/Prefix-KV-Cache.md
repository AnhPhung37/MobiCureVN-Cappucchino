# Prefix KV cache

Branch `final0.1-prefix-kv-cache-runtime`, built on all fifteen `final/*` branches merged
(`Docs/Test-Protocol.md` Appendix order). `final/prefix-kv-cache` made the prompt prefix stable
and testable; this branch reuses its KV cache at runtime.

## The opportunity

Every turn re-prefills the system prompt from token zero. The persona and constraints are ~545
tokens on Qwen 3.5, a confirmed profile adds up to ~200. From turn 2 on that work is identical.

## How it works

| Piece | File | Role |
|---|---|---|
| Planner | `App/Backend/Services/LLMService/PrefixCachePlanner.swift` | Pure rules: eligibility and cold / build / reuse, on token ids |
| Resume | `App/Backend/Services/LLMService/PrefixResume.swift` | Seeds a cache with the prefix; `PrefixResumingModel` continues from it |
| Wiring | `LLMService.startGeneration` | Cold requests keep `container.generate`; others run inside `container.perform` |
| Knob | `InferenceTuning.generation.prefixCache` | Ships `false` |

Per eligible chat request:

1. Tokenize the full templated prompt (as before). Never tokenize the prefix alone — BPE merges
   across the prefix/suffix boundary, so a separately tokenized prefix gives ids the model never sees.
2. **Reuse** when the kept prefix is exactly the start of this prompt and ≥1 token remains: copy the
   kept cache, prefill only the suffix.
3. Otherwise **build** when this prompt and the previous one share ≥128 tokens: prefill the shared
   part into a fresh cache, keep a copy, continue with the suffix. Same compute as cold.
4. Otherwise **cold**.

Turn 1 is cold, turn 2 builds, turn 3+ reuses. A language switch or profile edit changes the prefix,
so the next turn rebuilds.

### Eligibility (`PrefixCachePlanner.isEligible`)

- Knob on.
- Request has a system prompt. The auxiliary passes (classification, rewrite, extraction) have none,
  so they never use or evict the chat prefix — the eviction problem the groundwork doc flagged.
- No image or video in the prompt, and the previous generation on this model had none (below).
- No `maxKVSize` (rotating caches cannot be snapshotted faithfully once they wrap).
- `model_type` in `resumableModelTypes`: `qwen2`, `llama`, `phi3`, `gemma3_text`, `qwen3_5`.
  `qwen2_5_vl` and anything else stay cold until checked the same way.

### Two findings from the mlx-swift-lm 3.31.3 source

1. **The cache is never trimmed.** Qwen 3.5's linear-attention layers use `MambaCache`, a recurrent
   state with `isTrimmable == false`. Longest-common-prefix reuse by trimming would corrupt it. The
   snapshot therefore holds exactly the prefix and is only ever extended.
2. **Qwen 3.5's `prepare` is wrong on a seeded cache.** For text-only input it calls
   `resetPositionState()` and numbers positions from 0, ignoring `cache.offset`, so the suffix would
   be embedded at the wrong positions — fluent, wrong output. `TokenIterator` always calls `prepare`,
   so resumption wraps the model in `PrefixResumingModel`, whose `prepare` prefills the suffix
   through `callAsFunction`. That path numbers positions `cache.offset + i + ropeDeltas`, and
   `ropeDeltas` is zero after any text-only generation — hence the rule that a turn right after an
   image turn is cold. The text LLMs take positions from `cache.offset` (`applyRotaryPosition`) either
   way. Building the snapshot still goes through the model's own `prepare` on an empty cache, the
   path every cold request takes.

### Invalidation

- Model change: a new `LLMService`, new state.
- Memory warning and every `unload()`: snapshot, previous prompt and media flag cleared.
- Prefix change: the planner rebuilds.
- App background: not cleared. The snapshot is small (for Qwen 3.5 only its full-attention layers
  grow with tokens), and `unload()` on memory pressure already covers the real risk.

## Turning it on

1. On the target device and model:
   ```bash
   TEST_RUNNER_MOBICURE_BENCH=1 xcodebuild test -scheme MobiCureVN \
     -destination 'platform=iOS,name=<iPad>' \
     -only-testing:MobiCureVNTests/PrefixCacheCorrectnessTests
   ```
   It runs three turns cold, then three with the cache, at temperature 0, and requires the same
   opening 12 words per turn plus stats `cold 1 / built 1 / reused 1`. Different prefill chunking can
   flip a near-tie many tokens in; a mis-seeded cache diverges at once. **If it fails, leave the
   knob off.**
2. Set `"prefixCache": true` in `Documents/InferenceTuning.json` (no rebuild) or in the bundle.
3. Measure with `LatencyBenchmarkTests`, turn 1 (cold) against turns 2–10. The log line
   `prefix cache reuse: N of M prompt tokens` shows what was skipped.

Expected: roughly the prefix's share of prefill cut from turn 2 on — ~15–25% of prefill with the
3000-token context budget. Under ~10% measured, do not ship it.

## Tests

- `MobiCureVNTests/PrefixCachePlannerTests.swift` — every planner rule, no model.
- `MobiCureVNTests/PrefixCacheCorrectnessTests.swift` — device check above, skipped without
  `MOBICURE_BENCH=1`.
- `MobiCureVNTests/PrefixStabilityTests.swift` (from `final/prefix-kv-cache`) — the prefix really is
  byte-stable, which is what keeps the shared token prefix long.

## Not verified

No Swift was compiled for this branch (Linux, no Xcode). The MLX calls were written against the
3.31.3 sources (`ModelContainer.perform(nonSendable:)`, `TokenIterator`, `generateTask`,
`KVCache.copy()`, `LanguageModel.prepare`), not a compiler. Build first; then the device check.
