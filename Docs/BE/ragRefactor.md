# MobiCureVN — RAG Refactor Plan

> For LLM/dev context: this document lists the concrete problems that keep the current on-device RAG
> pipeline below production grade, and for **each** problem gives the full set of alternative fixes,
> ranked by fittingness for this codebase (⭐ = recommended pick). Format is **Problem → Alternatives**.
>
> Pipeline under review: `ChatService` → `MedicalChatOrchestrator` → `InputGuardRail` →
> `RAGService`/`SQLiteRetriever`/`QueryEmbedder` → `LLMService` (MLX, Qwen2.5-3B-4bit) → `OutputGuardRail`.
>
> Ranking legend per alternative: **Impact** (retrieval/answer quality or UX gain) · **Effort** ·
> **Risk**. Fittingness = best trade-off for an on-device, single-user, medical, iOS/MLX app.

---

## Priority tiers (TL;DR)

- **P0 — UX/correctness, do first:** #1 Fake streaming · #2 Chat template · #3 Generation params
- **P1 — retrieval quality:** #5 Real hybrid · #6 FTS query · #7 Reranker · #8 Confidence calibration
- **P2 — grounding/safety:** #10 Faithfulness check · #11 Guardrail robustness · #14 Medical anchors
- **P3 — supporting:** #4 Token counting · #9 Query refiner · #12 Eval harness · #13 Observability · #15 Embedder length · #16 Caching

---

## #1 — Fake streaming (buffered single yield)

**Problem:** `MedicalChatOrchestrator.swift:98-129` accumulates every token into `accumulatedResponse`
and `yield`s it **once** after generation completes, so the UI (`ChatViewModel.swift:175`) sees one
giant chunk. Perceived TTFT = full decode time (~20-100s). Output guardrail needs full text → the
buffering is intentional but kills UX.

**Alternatives (4):**
- ⭐ **1a. Optimistic stream + post-hoc redact.** Stream tokens live; keep the buffered copy; when the
  output guardrail trips (rare), replace the already-shown bubble with the filtered version.
  *Impact: high · Effort: med · Risk: med (user may briefly see unsafe text before redaction).*
- **1b. Fast pre-check → stream → light post-check.** Run a cheap safety gate on the first N tokens /
  first sentence, then stream the rest; full guardrail still validates at the end.
  *Impact: high · Effort: med · Risk: low-med.*
- **1c. Incremental sentence-level guardrail.** Buffer per sentence, validate each sentence, then
  release it. Streams in bursts (sentence granularity), never shows unsafe text.
  *Impact: high · Effort: high · Risk: low.* ← safest if we cannot ever show unsafe text.
- **1d. Keep buffering, add a "generating…" progress/skeleton UI.** No streaming, just better waiting UX.
  *Impact: low · Effort: low · Risk: none.* ← fallback only.

**Pick:** 1c if medical-safety is non-negotiable; else 1a for the biggest UX win at lower effort.

---

## #2 — Model chat template not used

**Problem:** `LLMService.swift:153-185` builds a raw `"System:/User:/Assistant:"` string and passes it
to `UserInput(prompt:)`, bypassing Qwen2.5's `<|im_start|>` chat template → measurably degraded output.

**Alternatives (3):**
- ⭐ **2a. Pass structured messages to MLX.** Use `UserInput(messages:)` (role/content array) so
  `container.prepare` applies the tokenizer's built-in chat template.
  *Impact: high · Effort: low · Risk: low.* ← clear best fit.
- **2b. Hand-render each model's template.** Manually emit `<|im_start|>system…` per `ModelCatalog`
  case. *Impact: high · Effort: med · Risk: med (breaks when swapping models).*
- **2c. Do nothing / rely on raw prompt.** *Impact: none · Effort: none · Risk: ongoing quality loss.*

**Pick:** 2a — smallest change, biggest quality-per-effort ratio in the whole doc.

---

## #3 — Generation parameters not tuned

**Problem:** `LLMService.swift:96` hardcodes `maxTokens: 1024, temperature: 0.7, topP: 0.9` — temp too
high for grounded medical answers, no repetition penalty, no stop tokens, long cap worsens #1.

**Alternatives (3):**
- ⭐ **3a. Lower temp + add penalties + trim cap.** `temperature ≈ 0.2-0.3`, add `repetitionPenalty`,
  set stop tokens, `maxTokens ≈ 512`. *Impact: med-high · Effort: low · Risk: low.*
- **3b. Make params configurable per request.** Surface `GenerateParameters` through `LLMRequest` so
  emergency/refine/answer stages differ. *Impact: med · Effort: med · Risk: low.*
- **3c. Keep defaults.** *Impact: none · Effort: none · Risk: verbose/creative medical output.*

**Pick:** 3a now, 3b when multiple LLM call-sites appear.

---

## #4 — Token budgeting uses word counts, no context guard

**Problem:** `applyContextBudget` (`MedicalChatOrchestrator.swift:219-231`) estimates tokens via
whitespace word count (`contextTokenBudget = 600`); total prompt is never token-counted and the LLM
context window is never set → silent overflow / truncation risk.

**Alternatives (3):**
- ⭐ **4a. Use the real tokenizer for counting + a total-prompt budget guard.** Count with the model's
  tokenizer; assemble system+context+history+user against the model's context length.
  *Impact: med · Effort: med · Risk: low.*
- **4b. Heuristic multiplier.** Keep word count but ×1.3 and add a hard ceiling. *Impact: low-med ·
  Effort: low · Risk: med (still approximate).*
- **4c. Keep as-is.** *Impact: none · Risk: prompt bloat / truncated context.*

**Pick:** 4a; 4b as a quick stopgap.

---

## #5 — Hybrid retrieval is FTS-first, vector is only a fallback

**Problem:** `SQLiteRetriever.swift:59-61` runs vector search **only when FTS returns fewer than
`candidateLimit`** rows. Most queries therefore skip semantic search — not true hybrid.

**Alternatives (4):**
- ⭐ **5a. Always run both, fuse with RRF.** Remove the "thin FTS" gate; run FTS + vector every query.
  *Impact: high · Effort: low · Risk: low (slightly higher latency — one extra embed+KNN).*
- **5b. Adaptive: run vector when FTS confidence/score is low.** Smarter gate than raw count (e.g.
  BM25 top-score threshold). *Impact: high · Effort: med · Risk: low.*
- **5c. Vector-first, FTS as keyword boost.** Invert the current design. *Impact: med · Effort: med ·
  Risk: med.*
- **5d. Keep FTS-first gate.** *Impact: none · Risk: semantic misses on paraphrased queries.*

**Pick:** 5a for correctness; move to 5b if the extra embed cost hurts latency on old devices.

---

## #6 — FTS query is over-broad and drops short tokens

**Problem:** `buildFTSQuery` (`SQLiteRetriever.swift:86-118`) joins all tokens with `OR` + prefix `*`,
and `tokenizeForFTS:114` drops tokens `< 3` chars → low precision, and important short/numeric medical
tokens are lost.

**Alternatives (3):**
- ⭐ **6a. Weighted AND-of-OR + keep meaningful short tokens.** Require base terms more strictly, OR the
  enriched terms, whitelist numbers/short medical tokens, add BM25 column weighting (section vs text).
  *Impact: high · Effort: med · Risk: med (need to retune recall).*
- **6b. Keep short tokens only.** Minimal fix: whitelist numeric/≤2-char medical tokens, leave OR logic.
  *Impact: med · Effort: low · Risk: low.*
- **6c. Keep as-is.** *Impact: none · Risk: noisy candidate set.*

**Pick:** 6b as a cheap win first, then 6a with an eval set (needs #12).

---

## #7 — No reranker after fusion

**Problem:** Retrieval stops at RRF (`mergeWithRRF`, `k=60`, `SQLiteRetriever.swift:360-386`). Production
RAG reranks the fused top-N with a cross-encoder for precision.

**Alternatives (4):**
- ⭐ **7a. On-device CoreML cross-encoder rerank of top-N.** Fetch more candidates, rerank down to
  `topK`. *Impact: high · Effort: med-high · Risk: med (added latency + model asset).*
- **7b. Lightweight lexical+semantic re-score.** Combine BM25 + cosine + credibility tier into one
  scorer (no new model). *Impact: med · Effort: low-med · Risk: low.*
- **7c. MMR diversity re-rank.** Re-order for relevance+diversity to cut near-duplicate chunks.
  *Impact: med · Effort: low · Risk: low.*
- **7d. No reranker.** *Impact: none · Risk: lower precision@k.*

**Pick:** 7b first (cheap, no asset), graduate to 7a if eval shows precision is the bottleneck.

---

## #8 — Confidence score is an uncalibrated heuristic that gates output

**Problem:** `calculateConfidence` (`SQLiteRetriever.swift:467-477`) uses hand-picked weights
(0.6/0.3/0.1 + tier boost); `OutputGuardRail` Check 2 **blocks** answers below
`minMedicalConfidenceThreshold` on this uncalibrated number → false blocks / false passes.

**Alternatives (3):**
- ⭐ **8a. Calibrate on an eval set + separate "block" gate from raw score.** Fit the threshold to
  labeled data (needs #12); use a calibrated probability. *Impact: high · Effort: med · Risk: low.*
- **8b. Replace heuristic with reranker score.** Use the cross-encoder score (#7a) as confidence.
  *Impact: med-high · Effort: med · Risk: low (depends on #7a).*
- **8c. Keep heuristic, only soften the action.** Warn instead of block on low confidence.
  *Impact: low · Effort: low · Risk: low.*

**Pick:** 8a once #12 exists; 8c as an immediate safety-vs-UX softener.

---

## #9 — Query refiner is a hardcoded dictionary, redundant with translation

**Problem:** `QueryRefiner.swift:37-96` hardcodes ~50 vi→en medical terms + keyword enrichment; for
Vietnamese input the text is **already** translated by Apple Translation
(`ChatService.swift:124`), so the dictionary mostly runs on already-English text — redundant and
non-scalable.

**Alternatives (4):**
- ⭐ **9a. Drop the vi→en dictionary; keep only light normalization/enrichment.** Rely on the existing
  translation for language; keep abbreviation expansion. *Impact: med · Effort: low · Risk: low.*
- **9b. Replace with an LLM refine / HyDE step.** Generate a hypothetical answer or rewritten query
  for embedding. *Impact: high · Effort: high · Risk: med (adds an LLM call → latency).*
- **9c. Data-driven synonym expansion.** Build the map from the corpus / a medical ontology instead of
  hand lists. *Impact: med · Effort: med · Risk: low.*
- **9d. Keep as-is.** *Impact: none · Risk: maintenance burden, silent gaps.*

**Pick:** 9a now (removes redundancy); consider 9b only if retrieval recall is proven weak.

---

## #10 — Output guardrail checks citations, not grounding/faithfulness

**Problem:** `OutputGuardRail.swift` verifies a citation exists and runs regex hallucination/dosage
checks, but never verifies the answer is **actually supported** by the retrieved chunks → hallucinations
that dodge the regexes still pass.

**Alternatives (3):**
- ⭐ **10a. Add a faithfulness check (answer↔context entailment).** Small on-device NLI / semantic
  overlap per claim vs retrieved chunks. *Impact: high · Effort: high · Risk: med.*
- **10b. Semantic-overlap heuristic.** Cheaper: require each advice sentence to have high cosine
  similarity to at least one chunk. *Impact: med-high · Effort: med · Risk: med (approx).*
- **10c. Keep regex-only.** *Impact: none · Risk: ungrounded advice reaches users.*

**Pick:** 10b as a pragmatic first step, 10a if a suitable small model is available.

---

## #11 — Guardrails are brittle regex/keyword lists

**Problem:** Input/Output guardrails (`InputGuardRail.swift`, `OutputGuardRail.swift`,
`GuardRailRules`) rely on hardcoded vi+en keyword/regex lists for dangerous/injection/PII/dosage →
easy to bypass, hard to maintain.

**Alternatives (3):**
- ⭐ **11a. Hybrid: keep regex fast-path + add embedding/classifier fallback.** Mirror the existing
  keyword→NLEmbedding pattern already in `checkMedicalRelevance`. *Impact: med · Effort: med · Risk: low.*
- **11b. Small on-device safety classifier.** Replace lists with a trained model. *Impact: high ·
  Effort: high · Risk: med.*
- **11c. Keep lists, just expand coverage.** *Impact: low · Effort: low · Risk: ongoing gaps.*

**Pick:** 11a — consistent with current architecture, bounded effort.

---

## #12 — No evaluation harness

**Problem:** No retrieval or answer metrics anywhere → every change above is unmeasurable; #6/#8 can't be
tuned safely.

**Alternatives (3):**
- ⭐ **12a. Offline eval set + retrieval metrics (recall@k, MRR) + answer faithfulness.** A small labeled
  Q→gold-chunk set run as a test target. *Impact: high (enabler) · Effort: med · Risk: none.*
- **12b. Retrieval-only eval.** Just recall@k/MRR, skip answer eval. *Impact: med · Effort: low · Risk: none.*
- **12c. Manual spot-checks.** *Impact: low · Effort: low · Risk: regressions slip through.*

**Pick:** 12a — it unblocks #6, #7, #8, #10. Do it early despite being P3-labeled.

---

## #13 — No observability beyond `print`

**Problem:** Only `print` statements; no per-stage latency (translate/embed/FTS/vector/prefill/decode)
or retrieval quality logging.

**Alternatives (3):**
- ⭐ **13a. Structured stage timing + signposts (`os_signpost`/OSLog).** Measure each pipeline stage.
  *Impact: med · Effort: low-med · Risk: none.*
- **13b. In-app debug overlay.** Show timings/scores in a dev panel. *Impact: med · Effort: med · Risk: none.*
- **13c. Keep prints.** *Impact: none · Risk: blind to regressions.*

**Pick:** 13a.

---

## #14 — Medical anchors use placeholder Kaggle credentials

**Problem:** `AppConfig.swift:67-68` ships `YOUR_KAGGLE_USERNAME/KEY`; if `Secrets.swift` is absent the
Kaggle loader fails and the domain filter silently falls back to keyword-only relevance.

**Alternatives (3):**
- ⭐ **14a. Bundle a curated anchors file offline.** Ship a vetted anchor list as an app resource; drop
  the runtime Kaggle dependency. *Impact: med · Effort: low · Risk: low.*
- **14b. Fix the credential/secret path.** Restore `Secrets.swift` and load at startup.
  *Impact: med · Effort: low · Risk: low (network dependency at startup).*
- **14c. Keep keyword-only fallback.** *Impact: none · Risk: weaker domain filtering.*

**Pick:** 14a — deterministic, offline-friendly for an on-device app.

---

## #15 — Embedder truncates queries at 128 tokens

**Problem:** `QueryEmbedder.swift:16` sets `maxSeqLen = 128`; `WordPieceTokenizer` truncates content to
126 tokens → long queries lose their tail before embedding.

**Alternatives (3):**
- ⭐ **15a. Raise `maxSeqLen` (e.g. 256) if the CoreML model supports it.** *Impact: med · Effort: low ·
  Risk: low (re-export model if fixed-shape).*
- **15b. Chunk long queries + mean-pool embeddings.** *Impact: med · Effort: med · Risk: low.*
- **15c. Keep 128** (fine for short chat queries). *Impact: none · Risk: rare truncation.*

**Pick:** 15c is acceptable for chat length; do 15a only if long queries are common.

---

## #16 — No caching of embeddings/context

**Problem:** Identical/repeated queries re-run embedding + FTS + vector every time.

**Alternatives (3):**
- ⭐ **16a. LRU cache query→embedding and query→context.** *Impact: med · Effort: low · Risk: low.*
- **16b. Cache embeddings only.** *Impact: low-med · Effort: low · Risk: low.*
- **16c. No caching.** *Impact: none · Risk: wasted compute on repeats.*

**Pick:** 16a — cheap latency win, especially on older devices.

---

## Suggested execution order

1. **P0 quick wins:** #2 (chat template) → #3 (params) → #1 (streaming).
2. **Enabler:** #12a (eval harness) — before touching retrieval scoring.
3. **Retrieval:** #5a (real hybrid) → #6b then #6a → #7b then #7a → #8a.
4. **Grounding/safety:** #10b → #11a → #14a.
5. **Supporting:** #4a, #9a, #13a, #16a, #15 (as needed).

> Each numbered problem is independently applyable. Alternatives labeled ⭐ are the recommended pick for
> this codebase; lower-ranked ones exist for when effort/risk budgets differ.
