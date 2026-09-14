# Prefix KV cache — what is done, and what is deliberately not

## The opportunity

The system prompt is re-prefilled from the first token on **every turn**. After
`final/prompt-slimming` the fixed persona and constraints are 317 words — about 545 tokens on
Qwen 3.5 at its measured 1.72 tokens per word — and a confirmed patient profile adds up to 200
more. That is roughly 550–750 tokens of identical work per turn, for the entire conversation.

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

`systemPrompt` is `stablePrefix + volatileSuffix` — nothing in between — so it is byte-for-byte the
prompt the single interpolated string produced, and nothing downstream changed. (The first version
joined the halves with an extra newline, which changed every prompt the model read;
`testSplittingThePromptDidNotChangeWhatTheModelReads` pins the join.)

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
   - the **token ids** of the chat-templated prompt it was built from, and the model identity;
   - the seeded `KVCache` itself.

   Key it on token ids, not on the `stablePrefix` string. A byte-identical prefix is necessary but
   not sufficient: the prompt is tokenized as a whole, and a BPE tokenizer can merge characters
   across the boundary — the suffix here always begins with newlines, and Qwen has single tokens
   for runs of newlines, so the last prefix token can differ between turns. Tokenize the full
   templated prompt each turn, find the longest common token prefix with the cached ids, and
   reuse the cache up to that length. Never tokenize the prefix on its own and splice: that
   produces token ids the model would not otherwise see.
3. **Thread the split through only if it helps.** With longest-common-prefix matching the cache
   does not need to know where `stablePrefix` ends; the split's job is to keep that common prefix
   long, which these tests already guarantee. Keep `systemPrompt` as the single thing sent.
4. **Keep auxiliary passes from evicting it.** Language classification and the two post-answer
   extraction passes run through the same `ModelContainer` between chat turns with entirely
   different prompts. A single-slot cache holding "the last prompt" is overwritten by them on every
   turn and never hits. Either keep one slot per prompt family (chat vs auxiliary), or move the
   auxiliary passes off the MLX container (the Foundation Models route in `final0.1-fm-aux-routing`).
5. **Invalidate on:** model change, language change, profile edit, memory-pressure warning
   (`AppConfig.observeMemoryWarnings` already exists — a cache that survives a memory warning is
   a leak with extra steps), and app background.
6. **Verify correctness before latency.** Same question, cold cache vs warm cache, must produce
   the same answer at temperature 0. If it does not, the cache is mis-seeded — stop.
7. **Then measure.** `MOBICURE_BENCH=1` with the latency harness, comparing turn 1 (cold) against
   turns 2-10 (warm). The expected shape is: turn 1 unchanged, later turns drop by roughly the
   prefix's share of prefill.

## Expected gain

A prefix of ~550–750 tokens against a context budget of 2000–3000 estimated tokens plus history
(after `final/context-budget-fix` and `final/retrieval-topk`). If prefill dominates TTFT, that is
roughly a **15–25% cut in prefill from the second turn onward** — smaller than it sounds when
retrieval context is large, which is exactly why it should be measured rather than assumed.

If the measured gain is under ~10%, do not ship it: a correctness-sensitive cache is not worth
carrying for a marginal win.
