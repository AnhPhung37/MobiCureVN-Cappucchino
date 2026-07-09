# MobiCureVN — Capstone B Roadmap & Claim Validation

> Prepared 2026-07-02. Scope: validate the project brief against the actual codebase,
> flag additional defects, assess feasibility for **5 people over 12 weeks**, and
> propose a rescoped, evidence-based plan.
> Line references point at the code state on branch `master` at time of writing.

---

## 1. Executive Summary

**Feasibility verdict: achievable in 12 weeks for a team of 5 — but only if the plan is
rescoped.** The brief's own roadmap spans **June → October (~20 weeks)**, not 12. The good
news: a large share of the "planned" work is **already implemented**, which frees budget.
The bad news: the brief lists several items as *to-do* that are done, and omits several real
bugs that are latent in the current code.

Headline correction: the biggest single item — *"Replace RAM-based vector storage with
`sqlite-vec`; verify hybrid FTS5 + KNN + RRF"* — **is already built** (`SQLiteRetriever.swift`).
The current retriever runs BM25 (FTS5) + vector KNN + Reciprocal Rank Fusion today. So the
June milestone is mostly complete, and the team can pull forward later work.

---

## 2. Claim Validation

Legend: ✅ Confirmed (real, open issue) · 🟡 Partially true / nuanced · ✔️ Already done ·
❌ Inaccurate.

### 2.1 Performance

| # | Brief claim | Status | Evidence |
|---|-------------|--------|----------|
| 1 | UI rebuilt on every streamed token | ✅ | `ChatViewModel.swift:166` — `rebuildSections()` runs inside the token stream loop; it regroups **all** messages (`ChatGrouper.group`) per token. |
| 2 | Incorrect chat template for all LLMs (Qwen/Llama need model-specific formatting) | ✅ | `LLMService.swift:138` `buildPrompt` emits generic `System:/User:/Assistant:` text, then passes it to MLX `UserInput(prompt:)` (`:83`). No model chat template / role tokens applied. |
| 3 | No generation timeout | ✅ | `LLMService.swift:85` `GenerateParameters(maxTokens: 1024, …)` caps length only; no wall-clock timeout anywhere. A hung MLX stream blocks the turn indefinitely. |
| 4 | Token buffer grows without bounds during streaming | ✅ | `LLMService.swift:72` `AsyncStream(bufferingPolicy: .unbounded)`. |
| 5 | No MLX memory-pressure handling | ✅ | No `MLX.GPU.set(cacheLimit:)` / memory callbacks in the codebase. |
| 6 | Entire inference pipeline runs on the main thread | 🟡 **overstated** | Generation already runs on `Task.detached(priority:.userInitiated)` (`LLMService.swift:73`) and orchestration on a `Task` (`MedicalChatOrchestrator.swift:42`). The *real* main-thread cost is UI-side: `rebuildSections()` per token on `@MainActor` (claim #1). Translation/refine/retrieval are `async` but some run on the main actor. |

### 2.2 RAG

| # | Brief claim | Status | Evidence |
|---|-------------|--------|----------|
| 7 | Keyword search is strict AND-only | 🟡 | `SQLiteRetriever.swift:81-92` — base tokens are joined with **AND**, but enriched terms use **OR**, and the two are OR'd together. So it is not purely AND, but the base clause is still AND-restrictive. |
| 8 | RAG executes twice per user message | ✅ | Retrieval #1 for generation: `MedicalChatOrchestrator.swift:79`. Retrieval #2 for citations: `ChatViewModel.swift:177` (`finalizeResponse`). Two independent retrievals per message. |
| 9 | Small knowledge base, "only one surgery/topic" | 🟡 | DB has **173 chunks / 9 docs / 5 orgs** (ACS, BCUK, NCCN, NCPD, WOCN). It already spans **multiple** colorectal topics (CRC, stoma reversal, urostomy, stenting, nutrition) — so "one topic" is inaccurate, but 173 « the 1,500 target is real. |
| — | *Replace RAM vector store with `sqlite-vec`* (June task) | ✔️ **done** | `SQLiteRetriever.swift` opens bundled `vectorstore.db`; tables `vec_chunks`, `chunks_fts` exist. Not in-memory. |
| — | *Verify hybrid FTS5 + KNN + RRF* (June task) | ✔️ **done** | `runFTS:125`, `runVectorSearch:275`, `mergeWithRRF:348` (k=60). Needs *validation*, not building. |
| — | *Fix `candidateLimit` bug* (June task) | ✅ | `SQLiteRetriever.swift:50` `max(topK*3, topK)` is a **no-op** (always `topK*3`). Dead defensive code; real intent unclear — needs a decision, not just a "fix". |

### 2.3 Design & Architecture

| # | Brief claim | Status | Evidence |
|---|-------------|--------|----------|
| 10 | Context budget capped ~600 words | ✅ | `MedicalChatOrchestrator.swift:143` `contextTokenBudget = 600`; `applyContextBudget:206` counts **words** (whitespace split), so the budget is ~600 words, not tokens. |
| 11 | Patient profile not used in prompts/retrieval | ✅ | No `PatientProfile` reference in `MedicalChatOrchestrator.swift` or any `RAG/*.swift`. |
| 12 | Models downloaded sequentially, not parallel | 🟡 **misframed** | Only the **one selected** model is downloaded (`AppConfig.swift:140`), so "parallel model downloads" is largely moot. The real inefficiency is **file-by-file** sequential download within a repo: `ModelManager.swift:315` `for … in downloadableFiles`. |

### 2.4 Roadmap items that are already true / done

- **Bundled embedding model / query embedder** exists: `QueryEmbedder.swift`, `WordPieceTokenizer.swift`, `Pipeline/convert_embedder.py`. (Verify it's actually bundled & not silently falling back — see §3.)
- **Evaluation harness** exists: `Pipeline/eval/` (IR + QA metrics, runner, dataset). The "50/30-question benchmark" tasks have tooling already.
- **SwiftData chat history** exists: `SwiftDataChatHistoryRepository.swift`.
- **Input/Output guardrails, emergency detector** exist and are unit-tested (`MobiCureVNTests/`).

---

## 3. Additional Issues Found (not in the brief)

Ranked by severity.

1. **Output guardrail runs *after* tokens are streamed to the user** (safety hole).
   `MedicalChatOrchestrator.swift:99` yields every token to the UI, then validates at `:105`.
   Unsafe/hallucinated content is already on screen before filtering; the "filtered" version
   is merely *appended*. This is the same item the brief lists for August ("move output
   guardrails before streaming") — but it is a **safety defect**, not a polish task, and
   should move to Phase 1.

2. **Citation ≠ generation context (mismatch bug).**
   The answer is generated from retrieval #1 (English `ragQuery`, `MedicalChatOrchestrator.swift:79`)
   but the citations shown come from retrieval #2 using a **different** query path
   (`queryRefiner.refineQuery(originalQuery)`, `ChatViewModel.swift:176`). The sources under a
   message may not be the sources the model actually read. Fixing #8 (dedupe RAG) fixes this too.

3. **Manual prompt formatting is double-wrapped.**
   `buildPrompt` (`LLMService.swift:138`) hand-rolls role labels, then hands the whole blob to
   MLX as a single `UserInput(prompt:)`. MLX will apply the model's chat template around it,
   so the model sees the entire conversation as one user turn — role/turn tokens are wrong for
   **both** Qwen and Llama. Root cause of claim #2; fix once, centrally.

4. **`InputGuardRail` compiles regexes on every call.**
   `InputGuardRail.swift:142,159` build `NSRegularExpression` inside loops per validation.
   (Brief mentions "precompile PII regexes" for Aug–Sep; it's cheap, do it early.)

5. **Dead code confirmed** (zero references):
   `App/Frontend/VVM/Common/ToolExecutor.swift`, `App/Backend/Store/ConversationMemory.swift`.
   Safe to delete now.

6. **`LLMService` default `modelPath` is a stale string** `"qwen-2.5-7b-instruct"`
   (`LLMService.swift:20`) while `ModelCatalog.default` is **Qwen 2.5 3B** (`ModelCatalog.swift:6,11`).
   Harmless (AppConfig overrides it) but misleading; the orchestrator comments assume a 3B model.

7. **`applyContextBudget` word-count ≠ token budget.** Underestimates real tokens for medical
   text; combined with the 600 cap this can silently starve context on longer chunks (claim #10).

8. **No cancellation of in-flight retrieval / translation** when the user cancels a stream —
   `cancelStreaming()` (`ChatViewModel.swift:198`) cancels the streaming task but detached LLM
   work and the second retrieval may still run.

---

## 4. Feasibility Analysis — 5 people, 12 weeks

**Scope vs. calendar mismatch.** The brief's roadmap is a ~5-month plan. Compressed to 12 weeks
it is *not* feasible **as literally written**. It becomes feasible once you subtract the work
already done (sqlite-vec, hybrid+RRF, eval harness, SwiftData history, guardrails, downloader,
embedder) and cut or defer stretch goals.

**Estimated effort of the *remaining real* work** (rough, person-weeks):

| Track | Remaining work | Est. |
|-------|----------------|------|
| Performance | timeout, bounded buffer, MLX cache limit, stop UI rebuild/token, diffable updates | ~3 pw |
| Correctness/safety | dedupe RAG (#8/#2), output guardrail pre-stream (#1), chat templates (#2/#3) | ~4 pw |
| RAG quality | KB expansion to 1,500+ chunks, relax AND, reranking, patient-aware retrieval, VN→EN terms | ~8 pw |
| UI/UX | streaming cursor, timestamps, patient name/date, PhotosUI, Speech, disclaimer, VN copy, kill placeholders | ~8 pw |
| Architecture | DI/protocols, remove AppConfig globals, ProfileRepository (SwiftData), MedicationStore migration, delete dead code | ~5 pw |
| Eval & hardening | run 30/50-Q benchmarks, memory profiling, 50-prompt & 30-min stress, defect fixing | ~5 pw |
| **Total** | | **~33 pw** |

A team of 5 over 12 weeks ≈ **~48–54 person-weeks** of raw capacity; net of meetings, ramp,
integration, and report/demo prep, plan for **~35–40 effective person-weeks**. So ~33 pw of
delivery is **tight but realistic** — with **little slack**. Protect it by:

- **Cut/defer stretch goals** unless core is green: cross-encoder reranking, LLM-based query
  rewriting, structured tool calls, session telemetry, voice + image (multimodal). Do **one**
  new modality well (recommend Speech *or* image, not both) if time allows.
- **Parallelize by track** — the 5 roles map cleanly to the tracks above; RAG/KB expansion and
  UI can run fully in parallel from week 1.
- **KB expansion is the schedule risk** (sourcing, licensing, chunking, QA of 1,500+ chunks).
  Start it in week 1 and run it continuously; it gates the eval numbers.
- **Freeze scope after week 8**; weeks 9–12 are integration, eval, and demo — do not add features.

---

## 5. Rescoped 12-Week Roadmap (recommended)

Assumes start ~2026-07-07. Bug fixes and safety first, features second, hardening last.

### Phase 1 — Weeks 1–3: Correctness, Safety & Perf Foundation
- Remove duplicate RAG; make citations come from the *same* retrieval used for generation (#8/#2).
- Move output guardrail to intercept **before** streaming (#1). Buffer + release only when safe.
- Fix chat templates: apply Qwen/Llama chat templates via the tokenizer instead of `buildPrompt` (#2/#3).
- Add generation timeout + bound the stream buffer + MLX cache limit / memory-pressure hook (#3,#4,#5).
- Stop `rebuildSections()` per token; update only the streaming message (#1).
- Delete dead code (`ToolExecutor`, `ConversationMemory`); fix stale `LLMService` default path (#6).
- Resolve `candidateLimit` (#): decide intended behaviour and document it.
- **Milestone:** correct, safe, non-janky single-turn chat on device.

### Phase 2 — Weeks 1–6 (parallel): Knowledge Base Expansion
- Source, clean, chunk, embed, index peer-reviewed docs → **1,500+ chunks**, multi-topic
  (CRC, post-op care, stoma, infection monitoring, nutrition). Reuse `Pipeline/`.
- Relax base FTS clause (AND→OR / weighted) (#7); expand VN→EN terms in `QueryRefiner`.
- Validate Top-3 accuracy on the fixed 30-Q benchmark via `Pipeline/eval/`.
- **Milestone:** expanded `vectorstore.db` with measured retrieval improvement.

### Phase 3 — Weeks 4–8: Patient Workflow & UI
- Streaming cursor, real timestamps, patient name + surgery date from `PatientProfile`.
- Patient-contextualized retrieval/prompt (#11): inject profile into system prompt + query.
- First-launch medical disclaimer/onboarding; standardize Vietnamese UI copy.
- Replace all placeholder `action: {}` buttons (2 found).
- **One** new input modality (Speech *or* PhotosUI) — treat as stretch.
- **Milestone:** functional patient-facing iPad app.

### Phase 4 — Weeks 8–10: Architecture Cleanup
- Introduce protocols + DI; remove direct `AppConfig` globals.
- SwiftData `ProfileRepository`; migrate `MedicationStore` off `UserDefaults`.
- Optimize `SwiftDataChatHistoryRepository.loadHistory()` with fetch predicates.
- Precompile guardrail regexes (#4); MARK sections + docs.
- **Milestone:** cleaner, testable backend.

### Phase 5 — Weeks 10–12: Evaluation, Hardening & Showcase
- Run 50-question bilingual eval: Top-3 accuracy, hallucination rate, first-token latency.
- 50-prompt crash test; 30-minute continuous physical-iPad session; 20-turn memory profiling.
- Fix critical defects; freeze; prepare demo scripts, device, report, slides, video.
- **Milestone:** production-ready prototype + demo assets.

### Deferred / stretch (only if green)
Cross-encoder reranking · LLM-based query rewriting · structured tool calls · session
telemetry · second input modality / full multimodal fusion.

---

## 6. Quick Reference — Confirmed Defects to File as Tickets

1. Output guardrail after streaming — `MedicalChatOrchestrator.swift:99/105` (safety)
2. Duplicate RAG + citation mismatch — `MedicalChatOrchestrator.swift:79`, `ChatViewModel.swift:177`
3. Wrong chat template (generic role text) — `LLMService.swift:138`, `:83`
4. No generation timeout — `LLMService.swift:85`
5. Unbounded stream buffer — `LLMService.swift:72`
6. UI regroup per token — `ChatViewModel.swift:166`
7. `candidateLimit` no-op `max()` — `SQLiteRetriever.swift:50`
8. Regex recompiled per call — `InputGuardRail.swift:142,159`
9. Sequential per-file model download — `ModelManager.swift:315`
10. Dead code — `ToolExecutor.swift`, `ConversationMemory.swift`
11. Stale default model path — `LLMService.swift:20`
12. Word-count "token" budget — `MedicalChatOrchestrator.swift:206`

---

## 7. Personal Notes — Additional Issues (2026-07-02)

### 7.1 OOM — App Quits Unexpectedly (Critical) — ✅ Fixed

The app crashed under memory pressure when running on-device. Fixed; see [`Docs/OOM-Memory-Management.md`](Docs/OOM-Memory-Management.md) for the full writeup (root causes, the fix, what was investigated but didn't need changing, and future optimization ideas).

Summary of the fix:
- **Unbounded stream buffer** (`LLMService.swift`, issue #5 above): `.unbounded` → `.bufferingNewest(512)`.
- **No MLX Metal cache limit** (issue from §3.5): added `MLX.Memory.cacheLimit = 512 * 1024 * 1024` after model load. Note: `MLX.GPU.set(cacheLimit:)` (as originally proposed) is deprecated in the pinned mlx-swift version — `MLX.Memory.cacheLimit` is the current API.
- **Model file downloads** (`ModelManager.swift:315`, issue #9): investigated — already streams to disk via `URLSession.download(for:)`, no change needed.
- **Memory-pressure hook**: added `LLMService.unload()` + `AppConfig.observeMemoryWarnings()` subscribing to `UIApplication.didReceiveMemoryWarningNotification`, releasing the model and force-clearing the MLX cache on pressure.

### 7.2 Citation Card Still Uses Mock Data

`CitationCard.swift` renders hardcoded placeholder source data rather than the real retrieval result. The underlying citation mismatch bug (#2 above) means even when wired up, the sources shown may not match what the model actually read.

- Fix the duplicate-RAG bug first (issue #2 / Phase 1 in §5), so generation and citation use the same retrieval pass.
- Then wire `CitationCard` to the `MedicalSource` objects returned from that single retrieval, using the tracked `documentName`, `pageStart` fields already on `MedicalSource.swift`.

### 7.3 Translation Is Not Stable

The on-device `Translation` framework (iOS 17.4+) produces inconsistent results:

- Apple's framework can fail silently or return `nil` when the language pair session hasn't warmed up — fallback handling in `TranslationService.swift` may be insufficient.
- Vietnamese diacritics detection in `LanguageValidationService` covers most cases, but code-switched input (mixed Vi/En within one sentence) can land in the wrong path.
- Medical terminology often has no consumer-grade translation equivalent (e.g., stoma reversal, urostomy, LARS score) — Apple's model will guess, producing noisy English queries passed to RAG.
- **Mitigation**: maintain an expanded override dictionary in `QueryRefiner` for known medical terms that Apple's model mistranslates; log translation inputs/outputs during testing sessions to spot failures.

### 7.4 Rule-Based RAG — Needs to Be More Advanced

The current retrieval is FTS5 BM25 + vector KNN + RRF, which is structurally correct, but the *query side* is still largely rule-based:

- `QueryRefiner` does manual Vietnamese→English mapping (~50 hardcoded terms) and abbreviation expansion. This won't scale to varied patient phrasing.
- The FTS base clause is AND-restrictive on the core query tokens, causing zero results on paraphrased or conversational queries.
- **Recommended improvements** (see also §3 Phase 2 / nextStep.md Tier 1):
  - Replace or augment manual term mapping with the on-device embedding similarity already available via `QueryEmbedder` — use it to expand the query at retrieval time, not just rerank.
  - Relax the AND clause to OR + BM25 scoring; the RRF fusion already handles noise from over-retrieval.
  - Consider LLM-based query rewriting (the model rewrites the patient's question into a retrieval-optimised form) as a stretch goal — the LLM is already on-device, so latency cost is just one extra short generation step.
  - Expand the corpus to 1,500+ chunks (see Phase 2 in `bugCheck.md`) to reduce the "no context found" fallback rate.

### 7.5 No CI/CD (Process Gap)

There is no `.github/workflows` directory and no automated build/test gate of any kind. Every merge so far (RAG fixes, translation fixes, guardrails) went in without CI validation — the team has been relying entirely on manual local testing before merge.

- **Risk**: a broken build or a regression in `MobiCureVNTests`/`MobiCureVNUITests` can land on `main` unnoticed until someone runs Xcode locally.
- **Recommended minimum**: a GitHub Actions workflow that runs `xcodebuild test` on PR against `main` (macOS runner, no signing needed for simulator tests). Even this alone would have caught regressions earlier in the RAG/translation fix history.
- **Stretch**: add a build step for `Pipeline/` (lint + a smoke run of `Pipeline/eval/run_eval.py` against the checked-in `qrels.jsonl`) so pipeline changes are also gated.

### 7.6 Dependency Pinning Is Inconsistent

- **SPM packages float on minimum versions.** `project.pbxproj` pins `swift-transformers`, `swift-huggingface`, `mlx-swift`, `mlx-swift-lm`, and `ZIPFoundation` via `upToNextMajorVersion` *minimums* (e.g. `≥ 1.3.2`), and **`Package.resolved` is gitignored**, not committed. Two people building the same commit on different days can silently resolve different minor/patch versions of `mlx-swift` — risky given how fast MLX's API surface moves, and it makes "it works on my machine" bugs hard to reproduce.
  - **Fix**: commit `Package.resolved` so builds are reproducible; bump deliberately via PR when needed.
- **`Pipeline/requirements.txt` pins every dependency exactly (`==`) except one**: `sqlite-vec` is listed with no version pin at all — notable because it's the exact package underlying the vector index that this document spends several sections discussing bugs in. An unpinned upgrade of `sqlite-vec` could silently change index behavior or file format compatibility with the bundled `vectorstore.db`.
  - **Fix**: pin `sqlite-vec` to the version actually used to build the currently-bundled `vectorstore.db`.

### 7.7 Repo Hygiene / Workspace Ownership

- **`build.log` (46KB) is committed at repo root** — a stray build artifact that should be removed and added to `.gitignore`.
- **Two competing Python workspaces exist for RAG corpus prep**: `Pipeline/` (has `requirements.txt`, `build_index.py`, `eval/` — clearly the active one) and `DocumentsChunking/` (a second, mostly-empty folder whose only substantial content is a 1.1GB uncommitted `.venv`). It's unclear whether `DocumentsChunking/` is abandoned, superseded, or still in use by someone.
  - **Fix**: confirm with whoever created `DocumentsChunking/` whether it's still needed; if not, delete it. If it serves a distinct purpose, document that purpose and move any unique logic into `Pipeline/`.
- **`README.md` is 2 lines** (title + "Capstone 2026") — no setup instructions, no architecture overview, no pointer to `bugCheck.md`/`nextStep.md`. Anyone new to the repo (new teammate, marker, future maintainer) has no entry point.
  - **Fix**: add a short README with build/run instructions for the Xcode project and the `Pipeline/` scripts, plus a link to these two roadmap docs.

### 7.8 Service-Locator Globals Instead of Real DI

`AppConfig` (`App/Backend/Configs/AppConfig.swift`) exposes `static var llmService`, `static var orchestrator`, `static let retriever`, `static let chatHistoryRepository` as process-wide mutable globals, with `didSet` triggering `NotificationCenter` broadcasts and orchestrator reconstruction. Protocols exist (`LLMServiceProtocol`, `ChatHistoryRepository`, `ProfileRepository`) but nothing is actually constructor-injected at a single composition root — this is a service-locator pattern wearing DI's clothes.

- **Consequence already observed**: `ChatViewModel` (UI layer) reaches directly into `AppConfig.retriever` to run its own second retrieval (see issue #2/#8) instead of going through `MedicalChatOrchestrator` — the global makes it too easy to bypass the intended layering.
- This is listed as a Phase 4 cleanup item in §5 above ("remove direct `AppConfig` globals"); flagging it here explicitly as its own finding since it's the root enabler of the layering violation in #2, not just unrelated tech debt.
