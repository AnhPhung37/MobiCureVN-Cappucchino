# MobiCureVN — Technical Assessment & Expansion Roadmap

_Last updated: 2026-07-02_

This document captures a technical assessment of the current app and a prioritized
set of expansion options, plus recommended benchmarks for evaluating output quality.

---

## What the app is today

MobiCureVN is an **on-device (MLX), bilingual (Vietnamese/English) iOS medical assistant**
narrowly scoped to **colorectal / bowel cancer + stoma care**.

Key components:

- **Hybrid RAG** over 9 curated authoritative PDFs (ACS, NCCN, Bowel Cancer UK, WOCN):
  FTS5/BM25 + `sqlite-vec` KNN fused with **Reciprocal Rank Fusion (RRF)**, on-device
  query embedding, and a confidence score with a credibility-tier boost.
  (`App/Backend/Services/RAG/SQLiteRetriever.swift`)
- **Guardrail pipeline**: input (dangerous / injection / PII / domain filter) →
  emergency detection → RAG → enriched prompt → LLM → output guardrail
  (citation enforcement, confidence threshold, hallucination / dosage filtering).
  (`App/Backend/Services/GuardRail/MedicalChatOrchestrator.swift`)
- **Offline-first**: everything runs on-device — a genuine privacy differentiator for a
  medical app.
- **IR evaluation harness** comparing chunking strategies. (`Pipeline/eval/`)

---

## 1. Is the technical side solid?

**Mostly yes — the architecture is strong for a capstone, with a few real gaps.**

### Strengths

- The hybrid retrieval + RRF design is the right call, and the eval **proves it matters**:

  | Chunking  | recall@5 | MRR   | nDCG@5 |
  |-----------|----------|-------|--------|
  | neural    | **1.00** | **0.88** | **0.90** |
  | semantic  | 0.125    | 0.05  | 0.07   |

  A real, defensible finding — lead with it in the report.
- On-device + offline + privacy is a legitimately standout angle.
- Clean layering (protocols, mocks, DI via `AppConfig`), shared SQLite connection,
  compiled-once regexes — engineering maturity.

### Weaknesses to address

1. **Generation quality is unevaluated.** In `eval_20260516T102004Z.json`,
   `answer_similarity` and `faithfulness` are both `0.0` because `answerer.type = "none"`.
   Retrieval is measured rigorously; the actual answers the user sees are not. **Biggest hole.**
2. **Guardrails are English-centric keyword/regex matching.** `OutputGuardRail.isMedicalAdvice()`
   only matches English phrases, so a Vietnamese response giving unsafe advice can **bypass
   citation enforcement and dosage filtering** — a safety hole for the primary user base.
   Substring matching in `checkDangerousRequests` / `checkPromptInjection` is trivially evaded.
3. **Eval set is `n=16` and English-only.** Fine as a smoke test; too small for statistically
   meaningful claims, and it never exercises the Vietnamese path (the differentiator).
4. **Hand-tuned magic numbers** (confidence weights `0.6/0.3/0.1`, threshold `0.45`, RRF `k=60`,
   600-token budget) aren't tied to any measured outcome.
5. **App still defaults to `MockLLMService`.** The real MLX path exists but isn't the default —
   validate on-device latency/quality, not just the mock.

**Net:** the retrieval spine is solid and measured; generation and the bilingual safety layer
are the soft spots.

---

## 2. Recommended benchmarks for evaluating output

The harness exists — priority is to **turn on generation eval** and add medical-specific rigor.

### Immediately (fills the biggest gap)
- **Wire up the answerer** so `answer_similarity` + `faithfulness` run against the on-device
  model's outputs instead of `none`.
- **RAGAS** (`faithfulness`, `answer_relevancy`, `context_precision`, `context_recall`) — the
  standard for RAG QA, with claim-level entailment that's far more defensible than the current
  homegrown cosine faithfulness in `metrics_qa.py`.
- **LLM-as-judge for groundedness/safety**: score "is every clinical claim supported by a cited
  chunk?" — measures hallucination in a way regex cannot.

### Medical-specific (strong for a capstone defense)
- **Faithfulness / attribution** is the metric that matters most in medicine.
- Sample questions styled after **MedQA / MedMCQA / PubMedQA** within the domain to stress-test
  factual grounding.
- **Refusal / safety eval set**: labeled out-of-domain, emergency, injection, and PII queries;
  report precision/recall of the guardrails (currently only unit-tested, no aggregate metric).

### Bilingual (measures the actual differentiator)
- Duplicate `queries.jsonl` in Vietnamese; report retrieval + generation metrics **per language**.

### Scale up
- Grow from 16 → 50–100 queries with proper `qrels` across all 9 docs before quoting numbers
  as conclusions.

---

## 3. Expansion options (ranked by impact-per-effort)

### Tier 1 — highest standout, builds on existing work
1. **Own the "grounded medical answers" story end-to-end.** Turn on generation eval, then add
   **inline sentence-level citations** (each claim links to its source chunk/page — `pageStart`
   is already tracked). "Every sentence is traceable to an authoritative source" is a killer demo.
2. **Make the safety layer genuinely bilingual.** Run `isMedicalAdvice` / dosage / emergency
   detection on both original VI and translated EN, then benchmark it. Turns the biggest weakness
   into a selling point.
3. **Structured medication + symptom tracking → personalized, grounded reminders.** Connect the
   existing `Medication` / `PatientProfile` / `DayDetailView` to the corpus: post-op day tracking,
   stoma-care checklists, "day 5 after stoma reversal, here's what to expect." A care companion,
   not a chatbot.

### Tier 2 — strong, moderate effort
4. **Query-time confidence UX**: surface `confidenceScore` honestly and offer escalation.
5. **Broaden the corpus within oncology GI** (more NCCN/ACS/reputable guidelines) so the
   "no context found" fallback fires less. Keep scope tight — depth beats breadth.
6. **Vietnamese voice input/output** — accessibility win for older patients; cheap on iOS.

### Tier 3 — flashy, handle with care
7. **Symptom-image / report-photo intake** (e.g., stoma appearance) — high wow-factor, high
   liability; only as clearly-labeled "informational, not diagnostic."
8. **Clinician-share mode**: export a conversation summary + tracked symptoms as a PDF the patient
   brings to their appointment.

---

## Recommended top 3 to maximize standout

- **(a)** Turn on generation/faithfulness eval + add inline per-sentence citations.
- **(b)** Make the guardrails genuinely bilingual and benchmark them.
- **(c)** Evolve the medication/profile screens into a grounded post-op care companion.

These reinforce each other and turn "another RAG chatbot" into a **privacy-preserving,
source-grounded, bilingual cancer-care companion.**

---

## 4. Next Steps — Existing Bugs (2026-07-02)

### 4.1 OOM — App Quits Unexpectedly

**Root causes (already identified in `bugCheck.md` §7.1):**
- Unbounded `AsyncStream` buffer accumulates all generated tokens in RAM (`LLMService.swift:72`)
- No MLX GPU cache limit — Metal cache grows freely and competes with OS memory budget
- Model files held in memory during sequential download (`ModelManager.swift:315`)

**Steps to fix:**

1. **Cap the stream buffer** — change `AsyncStream(bufferingPolicy: .unbounded)` to `.bufferingNewest(512)` in `LLMService.swift:72`. Tokens older than the buffer are already rendered; dropping them from the buffer is safe.
2. **Set an MLX GPU cache limit** — call `MLX.GPU.set(cacheLimit: 512 * 1024 * 1024)` (512 MB) inside `AppConfig` immediately after model load. Tune the value based on device RAM; a 6 GB device can afford more headroom.
3. **Register a memory-pressure hook** — implement `applicationDidReceiveMemoryWarning` in the app delegate (or subscribe to `UIApplication.didReceiveMemoryWarningNotification`) and clear the MLX KV cache and any in-memory RAG buffers there.
4. **Stream model file downloads** — in `ModelManager.swift:315`, write each file to disk as it downloads rather than buffering the full file in memory before writing.
5. **Test on the lowest-RAM target device** (not Simulator — Simulator shares host RAM). Run a 20-turn conversation and profile with Instruments → Allocations + Metal System Trace to confirm headroom stays positive.

### 4.2 Citation Card Still Uses Mock Data

**Root cause:** Two problems compound — `CitationCard.swift` is wired to placeholder data, and even when wired correctly, the citations come from a *second* retrieval pass with a different query than the one used for generation (`ChatViewModel.swift:177`), so the sources shown may not match what the model read (`bugCheck.md` §3 issue #2).

**Steps to fix:**

1. **Deduplicate RAG** — make generation and citation use the same retrieval result. In `MedicalChatOrchestrator.swift`, return the `[MedicalSource]` from the single retrieval at `:79` as part of the orchestrator's response. Remove the second retrieval in `ChatViewModel.swift:177`.
2. **Thread sources through the response** — add a `sources: [MedicalSource]` field to `LLMResponse` (the TODO already exists in `LLMResponse.swift`). Populate it from the orchestrator's retrieval result.
3. **Wire `CitationCard` to real data** — in `ChatViewModel`, when `finalizeResponse` is called, read `response.sources` and attach the `[MedicalSource]` to the `ChatMessage`. Pass them into `CitationCard` instead of the current placeholder.
4. **Display real fields** — `MedicalSource` already tracks `documentName`, `pageStart`, `organisation`, and `confidenceScore`. Render those in `CitationCard` directly.
5. **Handle the empty state** — show "No sources found" gracefully when `sources` is empty (low-confidence responses or out-of-domain queries), rather than hiding the card or showing stale mock data.

### 4.3 Translation Is Not Stable

**Root causes:** Apple's `Translation` framework can fail silently on cold sessions; medical terminology has no consumer-grade equivalent so the model guesses; and code-switched input (mixed Vi/En) can land on the wrong code path in `LanguageValidationService`.

**Steps to fix:**

1. **Warm up the translation session at app launch** — call `TranslationSession.translate` with a short dummy string during `AppConfig` initialization so the language pair is loaded before the first user message. This eliminates most cold-start failures.
2. **Add explicit error handling and retry** — `TranslationService.swift` should catch `TranslationError` cases explicitly and retry once before falling back. Log the failure with the original input so it's visible during testing sessions.
3. **Expand the medical term override dictionary in `QueryRefiner`** — Apple's model mistranslates domain-specific terms (stoma reversal, urostomy, LARS score, colostomy, anastomosis). Maintain a pre-translation substitution map in `QueryRefiner` that replaces known medical terms with their standard English equivalents *before* passing to the Translation framework. The existing Vietnamese→English map is a start; expand it to ~150+ terms.
4. **Improve code-switching detection** — `LanguageValidationService` currently treats diacritics as the primary signal. Add a secondary check: if NLLanguageRecognizer returns a low confidence score for any single language, treat the input as Vietnamese (the safer default for this app's user base).
5. **Log translation pairs during testing** — temporarily log `(input, translatedOutput)` to the console during real-device testing sessions. Review the log after each session to catch systematic mistranslations before they reach users.

### 4.4 Rule-Based RAG — Make It More Advanced

**Root cause:** `QueryRefiner` maps ~50 hardcoded Vietnamese terms to English and applies manual abbreviation expansion. This works for known patterns but fails on natural patient phrasing, synonyms, and any term not in the list. The FTS AND-clause then compounds this by returning zero results if any core token misses.

**Steps to fix (ordered by effort):**

1. **Relax the FTS AND clause to OR** — in `SQLiteRetriever.swift`, change the base query token join from `AND` to `OR`. BM25 scoring naturally demotes weak matches; the RRF fusion step already handles noise from over-retrieval. This is a one-line change with measurable recall improvement.
2. **Expand the Vietnamese→English term map** — grow from ~50 to ~150+ entries covering common patient questions about post-op care, stoma management, nutrition, pain, infection signs, and medication. Source terms from the existing 173-chunk corpus: extract the most frequent medical nouns and ensure they're in the map.
3. **Use `QueryEmbedder` for query expansion** — `QueryEmbedder.swift` and `WordPieceTokenizer.swift` are already built. At retrieval time, embed the refined query and find the top-5 most similar chunk embeddings; use their keywords to augment the FTS query. This replaces the manual map for long-tail terms.
4. **Add LLM-based query rewriting as a stretch goal** — before retrieval, run one short LLM generation step that rewrites the patient's conversational question into a retrieval-optimised form (e.g. "What are the signs of stoma infection?" → "stoma infection symptoms redness swelling discharge fever"). The LLM is already on-device; the extra latency is one short generation (~200 tokens). Gate this behind a flag so it can be disabled if latency is unacceptable.
5. **Benchmark each change** — the `Pipeline/eval/` harness exists. After each of the above steps, run the 30-question benchmark and record `recall@5` / `MRR` / `nDCG@5`. Keep only changes that improve the numbers. The current neural-chunking baseline (`recall@5 = 1.00`) is the ceiling to preserve.

---

## 5. Personal Notes — Features to Add (2026-07-02)

### 5.1 Profile / Auth Database

The app currently has a `PatientProfile` data structure and a basic `ProfileView` UI, but no authentication layer and no persistent, secure profile store. Real patients will test this, so this gap needs to close before any user-facing deployment.

**What's needed:**

- **Local authentication**: use `LocalAuthentication` (Face ID / Touch ID / passcode) to gate app entry. No login screen required — just `LAContext.evaluatePolicy(.deviceOwnerAuthentication)` on launch. This is the minimum bar for a medical app on a shared device.
- **Persistent profile store via SwiftData**: replace any in-memory or `UserDefaults`-backed profile storage with a `@Model`-annotated `PatientProfile` entity in SwiftData. A `ProfileRepository` protocol already exists — wire a `SwiftDataProfileRepository` the same way `SwiftDataChatHistoryRepository` is done.
- **Profile → prompt injection**: once persisted, inject the patient's name, diagnosis, surgery date, and stoma type into the LLM system prompt and RAG query in `MedicalChatOrchestrator`. The `PatientProfile` fields exist; they're just never read by the pipeline (confirmed defect §2.3 issue #11 in `bugCheck.md`).
- **Profile → per-patient chat isolation**: associate `ChatRecord` in SwiftData with a `patientId` so if multiple profiles exist on one device, conversations don't bleed between them.

**Scope note:** a full backend auth service (OAuth, JWT, remote user DB) is out of scope for an on-device capstone. Local biometric auth + SwiftData is the right level.

### 5.2 Security (Real Patients Will Test This)

The app processes sensitive health information. Before real patients interact with it, a security pass is mandatory.

**Data at rest:**
- SwiftData stores chat history and will store profile data in the app's sandbox. Ensure the `NSPersistentStore` is created with `NSPersistentStoreFileProtectionKey: .completeUnlessOpen` so data is encrypted by the OS when the device is locked.
- `Secrets.swift` (Kaggle credentials) is already gitignored — confirm it is never bundled into the release build (add a build phase script that fails if `Secrets.swift` contains non-placeholder values).

**Data in transit:**
- The app is offline-first — no network calls for LLM or RAG, which is a strong privacy property. Confirm no analytics SDK, crash reporter, or third-party framework is phoning home. Audit the SPM dependency list for network activity.

**PII handling:**
- `InputGuardRail` already masks phone numbers, emails, and IDs in user input before passing to the LLM. Verify masked output is what gets stored in `ChatRecord`, not the original — check `ChatViewModel.swift` where messages are persisted.
- Add a visible **data usage disclaimer** on first launch (required for any medical app and for ethics board approval): what data is stored, where it lives (on-device only), and how to delete it (delete the app).

**Prompt injection:**
- `InputGuardRail.checkPromptInjection` uses substring matching which is bypassable (noted in `nextStep.md` §1 weakness #2). Before real patients test it, consider adding an NLEmbedding semantic check for injection intent (the same pattern used for the domain filter) as an additional layer.

**Session hygiene:**
- Add a "Clear all data" option in the profile screen that wipes SwiftData stores and cached model files — patients may share devices or hand over a phone.
- Consider auto-lock: if the app goes to background and returns after N minutes, require biometric re-auth before showing chat history.

### 5.3 Persistence Is Split Across Three Uncoordinated Mechanisms

The app currently persists state through three different mechanisms, each with its own error-handling convention and no shared abstraction between them:

- **Raw SQLite3 C API** (`SQLiteRetriever.swift`) for the read-only bundled `vectorstore.db` — failures fall back silently to an empty `RetrievedContext` rather than surfacing an error.
- **SwiftData `@Model`** (`SwiftDataChatHistoryRepository.swift`) for chat history — throws typed SwiftData errors.
- **`UserDefaults`** (`AppConfig.swift`) for app/model settings (`UseRealLLM`, `SelectedLLMModel`) — reads return silently-defaulted optionals.

**Why this matters now:** §5.1 above proposes adding a `SwiftDataProfileRepository` for `PatientProfile`, which will be a fourth persisted entity. Without a documented convention, it's a coin flip which of the three existing patterns (or a new one) gets used, and error handling will likely diverge again.

**Recommendation:** before adding `ProfileRepository`, write a one-paragraph convention (e.g., "all app-owned mutable data goes through SwiftData with a `Repository` protocol; `UserDefaults` is only for non-critical UI/feature-flag state; the bundled vector store remains read-only raw SQLite since it's never written by the app") and apply it consistently as new persisted state is added.

### 5.4 Cross-Reference

See `bugCheck.md` §7.5–7.8 for related findings from a full architecture pass: missing CI/CD, inconsistent dependency pinning (`Package.resolved` not committed, `sqlite-vec` unpinned), repo hygiene issues (stray `build.log`, duplicate `DocumentsChunking/` Python workspace, empty `README.md`), and the `AppConfig` service-locator pattern that enables the citation/generation mismatch bug in §4.2.
