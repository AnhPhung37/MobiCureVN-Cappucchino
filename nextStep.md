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
