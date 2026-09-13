# 2026 IT & Engineering Capstone Project Information — MobiCureVN

> Draft for the Capstone Showcase & Award Ceremony 2026 submission form.
> Fields marked **[CONFIRM]** need details that aren't in the repository.

---

## 1. Project title

**MobiCureVN — An offline, bilingual on-device AI companion for post-surgical colorectal recovery**

Short form: **MobiCureVN**

## 2. Team

Team name: **Cappucchino**

| Member                                      | Role                                                        | Student ID               |
| ------------------------------------------- | ----------------------------------------------------------- | ------------------------ |
| **[Do Le Trang Hanh]**                      | Backend / LLM pipeline                                      | **[s3977994]**           |
| **[Nguyen Minh Quan]**                      | RAG & data pipeline                                         | **[s3979391]**           |
| **[Phung Thi Minh Anh, Trinh Phuong Thao]** | iOS frontend / design system                                | **[s3986878, s3979297]** |
| **[Le Thien Son]**                          | Safety & evaluation, document processing, document chunking | **[s3977955]**           |

Supervisor: **[Dr. Arthur Tang, Dr. Tom Huynh]**
Industry sponsor / client: **[RMIT SSET]**

## 3. Abstract (≈200 words)

Patients recovering from colorectal cancer surgery in Vietnam leave hospital with a
stoma or a healing wound and very little continuous support. Reliable guidance is
mostly in English, clinicians are hard to reach between appointments, and the
questions that matter most — _is this discharge normal? when is this an emergency?_ —
are exactly the ones patients are least comfortable asking.

MobiCureVN is an iOS 26 application that puts a Vietnamese-speaking recovery
assistant on the patient's ipad. Every component runs **on-device**: a
4-bit quantised large language model via MLX Swift, a local retrieval-augmented
generation index built from 39 curated clinical documents (NCCN, NHS, UOAA;
1,238 chunks in SQLite with hybrid vector + full-text search), Apple's on-device
Translation framework, and a vision-language model for wound-photo triage. No
patient text, chat history, or wound photograph ever leaves the device.

Answers are grounded in the retrieved clinical sources and shown with citations.
A dedicated emergency detector runs on the patient's original Vietnamese wording
before any translation or generation step, so red-flag symptoms trigger a direct
"seek care now" redirect rather than a generated answer. Input and output
guardrails sit either side of the model to keep it an assistant, never a
diagnostician.

## 4. Problem statement

- Post-operative colorectal / ostomy patients need daily, low-stakes answers, but
  the support gap between discharge and follow-up is where most anxiety and
  avoidable readmission risk lives.
- Authoritative material is English-language and written for clinicians.
- Cloud AI assistants are a privacy non-starter for wound imagery and medical
  history, and assume connectivity that patients at home may not have.

## 5. Solution / approach

| Layer                  | What we built                                                                                                                                                                                                                                                                                    |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **On-device LLM**      | MLX Swift running 4-bit quantised model; catalogue spans Qwen 3.5 4B                                                                                                                                                                                                                             |
| **RAG**                | Offline Python ingestion pipeline (parse → clean → neural chunk → enrich → index) producing a `vectorstore.db` shipped in the app bundle; on-device hybrid retrieval combining `sqlite-vec` KNN and FTS5 BM25 fused with Reciprocal Rank Fusion, queries embedded by a CoreML build of BGE-small |
| **Bilingual pipeline** | LLM language detection and refinement, Apple Translation VI→EN inbound, English-only medical core, LLM back-translation with a validation pass and Apple Translation fallback                                                                                                                    |
| **Safety**             | Emergency detector on original-language text before generation; input guardrail (jailbreak, out-of-scope, self-harm); output guardrail (diagnostic-language, citation and PII checks)                                                                                                            |
| **Wound analysis**     | Vision-language model over a downscaled on-device photo, with a structured findings parser and a local wound log                                                                                                                                                                                 |
| **Memory**             | Per-conversation session-fact store and a persistent patient profile, injected into the system prompt so facts survive the short context window                                                                                                                                                  |
| **App**                | SwiftUI, MVVM + Clean Architecture, custom design system, Vietnamese-default localisation, VoiceOver and text-scaling support                                                                                                                                                                    |

## 6. Technologies

Swift 6 · SwiftUI · SwiftData · iOS 26 · MLX Swift · CoreML · Apple Translation
framework · SQLite (`sqlite-vec`, FTS5) · Python (pymupdf4llm, chonkie,
sentence-transformers) · XCTest

## 7. Outcomes

- A working iOS application demonstrating a full offline clinical RAG + LLM
  pipeline with no server component.
- A reproducible document-ingestion pipeline over a 39-document, 1,238-chunk
  curated corpus, with a 209-query golden-set retrieval evaluation harness.
- A safety test suite (21 test files) covering emergency detection including
  adversarial phrasing, guardrail bypass attempts, bilingual output filtering,
  PII masking collateral damage, and language drift.
- A published engineering audit identifying the remaining accuracy levers
  (embedder pooling alignment, cross-encoder reranking, chunk-size limits,
  classifier-based guardrails, Vietnamese-language evaluation coverage).

## 8. Impact / significance

Demonstrates that a privacy-preserving, Vietnamese-first clinical assistant is
feasible entirely on consumer hardware — relevant wherever medical data
sensitivity, language coverage, or connectivity rule out cloud AI.

## 9. Keywords

on-device AI · retrieval-augmented generation · healthcare · colorectal cancer ·
ostomy care · Vietnamese NLP · privacy-preserving machine learning · iOS · MLX ·
AI safety guardrails

## 10. How it works — the journey of one question

A patient asks, in Vietnamese, *"Vết mổ của tôi chảy dịch vàng, có sao không?"*
Everything below happens on the iPad, with the network switched off.

1. **Understand the language.** The on-device model detects the language and
   silently repairs typos and Vietnamese/English code-switching, without changing
   what was asked.
2. **Check for an emergency — first, and in the patient's own words.** The
   emergency detector runs on the original Vietnamese text, *before* translation,
   guardrails, or the model. Red-flag wording (heavy bleeding, breathing
   difficulty, signs of sepsis) short-circuits everything and returns a direct
   "seek care now" redirect with emergency contacts. The LLM is never invoked on
   an emergency turn — there is no opportunity for it to reassure someone who
   needs an ambulance.
3. **Translate inward.** Apple's on-device Translation framework converts the
   question to English, because the clinical corpus, the guardrails and the
   model's strongest reasoning all live in English.
4. **Screen the request.** The input guardrail rejects jailbreak attempts,
   out-of-scope requests, and self-harm content.
5. **Retrieve the evidence.** The query is embedded on-device by a CoreML build
   of BGE-small and searched against the bundled index two ways at once —
   semantic vector similarity (`sqlite-vec`) and keyword search (SQLite FTS5) —
   fused with Reciprocal Rank Fusion. The top 5 passages, with their source
   organisation and credibility tier, become the grounding context.
6. **Generate the answer.** Qwen 3.5 4B (4-bit, via MLX Swift on the Apple
   Neural Engine / GPU) writes an answer using only those passages, the
   patient's profile, and the facts remembered from this conversation.
7. **Screen the answer.** The output guardrail inspects the *complete* response
   before the patient sees any of it — stripping diagnostic phrasing, checking
   citations are present, and masking PII. Nothing streams past the safety layer
   unchecked.
8. **Translate back, and verify.** The model translates its own answer to
   Vietnamese (noticeably warmer than literal machine translation), then a
   validation pass confirms the result is complete and in the right language.
   If it isn't, Apple Translation takes over as the fallback.
9. **Show the receipts.** The answer arrives with the clinical sources it was
   built from, so the patient — or their nurse — can check where it came from.

**Wound photos** follow a parallel path: the image is downscaled on-device, read
by a vision-language model, parsed into structured findings, and written to a
local wound log so changes can be tracked over time. The photo never leaves the
iPad.

## 11. How well it performs

### Retrieval accuracy — measured

Evaluated against a hand-labelled golden set of **209 clinical questions**, using
a Python port of the exact retriever that ships in the app (`Pipeline/eval/`):

| Configuration | recall@5 | MRR | nDCG@5 | doc-hit@5 |
|---|---|---|---|---|
| Original hybrid | 0.187 | 0.097 | 0.119 | 0.689 |
| Vector-only | 0.239 | 0.170 | 0.187 | 0.756 |
| **Shipped (hybrid + always-fuse + stopword drop)** | **0.249** | **0.159** | **0.181** | **0.770** |

**Read `doc-hit@5` as the headline: 77% of questions retrieve the correct source
document in the top 5.** Exact-chunk recall understates real performance because
most queries have a single labelled gold chunk, and the retriever frequently
returns an equally correct *neighbouring* passage from the same document.

The evaluation harness is reproducible and versioned, so every retrieval change
is measured rather than assumed — the always-fuse fix alone lifted recall@5 from
0.187 to 0.249 (+33%) and doc-hit from 0.689 to 0.770.

### Safety coverage — measured

**337 automated tests** across 21 suites, concentrated on the safety-critical
paths: emergency detection (including an adversarial suite of deliberately
obfuscated and indirect phrasings), input-guardrail bypass attempts, output
filtering in both Vietnamese and English, PII-masking collateral damage, language
drift, and RAG citation integrity.

### Speed and footprint

- **Fully offline inference** — no network round-trip in the response path, so
  performance does not degrade on poor connectivity, and there is no per-query
  API cost.
- **4-bit quantisation** via MLX Swift, running on the Apple Neural Engine and
  GPU, is what makes a 4B-parameter model viable on tablet hardware at all.
- **Bounded memory.** The token buffer is capped, the MLX Metal cache is capped
  at 512 MB, and the app releases GPU memory on system memory-pressure warnings —
  addressing the jetsam terminations that unbounded buffers previously caused.
- **Answers are delivered complete, not streamed.** This is a deliberate safety
  trade-off: the output guardrail must see the whole response before the patient
  sees any of it. The cost is a wait with a progress indicator instead of
  token-by-token text.
- A Vietnamese turn costs several model round-trips (detect/refine → generate →
  fact extraction → translate → validate), which dominates response time;
  on-device query embedding adds a few hundred milliseconds.

> **[MEASURE]** — end-to-end response time, time-to-first-answer and tokens/sec on
> the demo iPad Air M5 are not yet benchmarked in the repository. Record these on
> the showcase device before submitting; do not quote a number you have not
> measured on that hardware.

## 12. How privacy works

**The design guarantee: no patient content ever leaves the device — because there
is no server to send it to.**

This is architectural, not a policy promise. MobiCureVN has no backend. There is
no account, no login, no telemetry, no analytics SDK, and no crash reporter that
could carry user content off the iPad.

| What | Where it lives |
|---|---|
| Chat history (including attached images) | Local SQLite / SwiftData store on the device |
| Patient profile & remembered facts | Local store, injected into the prompt at query time |
| Wound photographs & wound log | Local only, downscaled on-device before analysis |
| Language model & inference | On-device, MLX Swift — prompts never transit a network |
| Translation | Apple's on-device Translation framework, not a cloud API |
| Clinical corpus | A read-only SQLite index shipped inside the app bundle |

**The only network traffic the app makes** is a one-time download of assets:
model weights from Hugging Face and the guardrail's medical-term dataset. These
are outbound *fetches* — nothing patient-generated is ever uploaded. Once the
assets are present the app functions with the network disabled, which is how it
is demonstrated.

**PII masking** runs as part of the output guardrail as an additional layer, so
identifying details are stripped from generated text even though that text never
travels anywhere.

**Why this matters commercially:** wound photographs and post-operative history
are among the most sensitive data a person has. An architecture with no server
removes an entire class of risk — no breach surface, no data-residency question,
no third-party processor agreement, and no dependency on a vendor's retention
policy. It also means the app works in a rural clinic with no connectivity.

## 13. Showcase logistics — **[CONFIRM]**

- Demo format (live device demo / poster / video): **[CONFIRM]**
- Hardware required (iPad Air M5 16GB RAM: **[CONFIRM]**
