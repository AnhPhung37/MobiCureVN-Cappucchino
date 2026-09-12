# Prefix KV cache — what is done, and what is deliberately not

## The opportunity

The system prompt is re-prefilled from the first token on **every turn**. After
`final/prompt-slimming` the fixed persona and constraints are ~488 tokens, and a confirmed
patient profile adds up to 200 more. That is ~700 tokens of identical work per turn, every
turn, for the entire conversation.

Reusing the KV cache for that prefix is the largest remaining time-to-first-token win in the
app — larger than anything left in retrieval or prompt assembly, because it removes work
rather than shrinking it.

## What this branch does

It makes the prefix **a real thing that can be cached, and proves it is stable.**

`MedicalChatOrchestrator.EnrichedPrompt` now carries two explicit halves instead of one
interpolated string:

- `stablePrefix` — language directive, invariant persona and constraints, confirmed profile,
  context-language note. Changes only when the patient switches language or edits their profile.
- `volatileSuffix` — retrieved chunks, sources, confidence, session facts, no-context note.
  Changes every turn.

`systemPrompt` is `stablePrefix + "\n" + volatileSuffix`, so nothing downstream changed.

`MobiCureVNTests/PrefixStabilityTests.swift` then asserts the property the whole optimisation
depends on: the prefix is byte-identical across different questions, different retrieved
context, accumulating session facts, growing history, the empty-context branch, and repeated
identical calls — and that it *does* change with language and with the profile, because a
cache keyed on it must miss in exactly those cases.

**Why this is the valuable half.** "The top of the prompt is stable" was previously a claim in
a comment. One stray interpolation — a timestamp, a turn counter, a `Set` iterated in
non-deterministic order — silently defeats a prefix cache while everything still looks correct,
and the symptom is "the optimisation did nothing", which is very hard to debug. These tests
turn that from a hope into a contract, and they cost no MLX runtime to run.

## What this branch does NOT do

**It does not reuse the KV cache at runtime.** That was a deliberate decision, not an oversight.

`LLMService` uses only the high-level `container.generate(input:parameters:)`, which builds a
fresh cache per call. True prefix reuse means dropping to `ModelContainer.perform { context in … }`
and driving a `TokenIterator` with a pre-seeded `KVCache` — an API surface that could not be
verified in the environment this change was written in (no Xcode, no resolved packages; see
`Docs/BE/mlxApiVerification.md`).

That matters more here than elsewhere because of the failure mode. A mis-seeded KV cache does
not crash and does not throw: it produces **fluent, plausible, wrong tokens**. In a medical
assistant, a silent correctness failure written blind and shipped a week before a presentation
is the wrong trade. A compile error would have been fine; this would not fail loudly.

## How to finish it

Prerequisite: `final/mlx-runtime-knobs` merged and `Package.resolved` committed, so the API is
pinned and readable.

1. **Read the real API.** ⌘-click `ModelContainer`, `TokenIterator` and `KVCache` in the
   resolved `mlx-swift-lm`. Confirm how a cache is constructed, seeded with a token prefix, and
   handed to the iterator.
2. **Add a `PrefixCache` to `LLMService`**, holding:
   - the `stablePrefix` string it was built from (the cache key — compare by value, and only
     reuse on an exact match);
   - the model identity, so switching models in the picker invalidates it;
   - the seeded `KVCache` itself.
3. **Thread the prefix through.** `LLMRequest` currently carries one `systemPrompt`. Add the
   split so `LLMService` can tokenize the prefix separately and know where the reusable region
   ends. Keep `systemPrompt` working for every other caller.
4. **Invalidate on:** model change, language change, profile edit, memory-pressure warning
   (`AppConfig.observeMemoryWarnings` already exists — a cache that survives a memory warning is
   a leak with extra steps), and app background.
5. **Verify correctness before latency.** Same question, cold cache vs warm cache, must produce
   the same answer at temperature 0. If it does not, the cache is mis-seeded — stop.
6. **Then measure.** `MOBICURE_BENCH=1` with the latency harness, comparing turn 1 (cold) against
   turns 2-10 (warm). The expected shape is: turn 1 unchanged, later turns drop by roughly the
   prefix's share of prefill.

## Expected gain

Prefix ~700 tokens of a ~3000-token prompt (after `final/context-budget-fix` and
`final/retrieval-topk`). If prefill dominates TTFT, that is a **~20-25% cut in prefill from the
second turn onward** — smaller than it sounds when retrieval context is large, which is exactly
why it should be measured rather than assumed.

If the measured gain is under ~10%, do not ship it: a correctness-sensitive cache is not worth
carrying for a marginal win.
