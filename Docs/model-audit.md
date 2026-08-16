# MobiCureVN — Model/System Audit

On-device (MLX, 4-bit) VI↔EN medical RAG chatbot. SQLite (`sqlite-vec` + FTS5) hybrid retriever over **1238 chunks / 39 docs**. Apple Translation, regex guardrails, VLM wound path.

Latest eval (hybrid, k=5): **recall@5 0.187 · MRR 0.097 · nDCG@5 0.119** · QA metrics 0 (answerer off).
## 🔴 Correctness bugs (silent quality loss)

- **Embedder pooling mismatch.** Corpus = CLS pooling (`bge-small` `1_Pooling/config.json: pooling_mode_cls_token=true`), on-device query embedder = **mean pooling** (`convert_embedder.py:37-42`, comment falsely says "matches"). Query vs doc vectors in different spaces → on-device vector search degraded. Eval can't see it (Python embeds both sides via SentenceTransformer). **#1 fix.**
- **Confidence score can't be low & ignores similarity.** RRF scores max-normalized → top always 1.0; `calculateConfidence` ≥0.6 always (`SQLiteRetriever.swift:350-355,437-447`). The `<0.65` low-confidence guard never fires; "Confidence %" in prompt is inflated noise.
- **Citations page-less.** `page_start` NULL for all 1238 chunks — chonkie/pymupdf never emit pages (`enrich_chunks.py:54-61`, `chunk.py`). `MedicalSource.page` always 0.
- **Oversized chunks truncated.** BGE limit 512 tok, but **219/1238 (17.7%) >512, 95 >1024, max 13664** tok. Embedded from first 512 only. `chunk.py:24` sets min but no max.

## 🟠 RAG — Retrieval

- **No reranker** (no cross-encoder / bge-reranker / ColBERT / MMR). Highest-ROI add over top-15.
- **Eval ≠ prod.** Eval runs `always_fuse=False, drop_stopwords=False` (`runner.py`, `experiment_config.json`); shipped Swift always-fuses + drops stopwords (`SQLiteRetriever.swift:57-61`). Headline recall is for an abandoned config.
- **Query understanding = 60-entry hand dict** (`QueryRefiner.swift:32-146`). Missing HyDE, multi-query/RAG-fusion, LLM rewrite, UMLS/SNOMED synonyms.
- **VN normalization dead in main path** — runs after EN translation.
- **FTS crude:** porter/ascii, OR-of-prefix wildcards, no field weighting/proximity; dedupe by 200-char prefix drops distinct chunks (`SQLiteRetriever.swift:383-400`).
- **Embedder upgrade never run** — `bge-base`/`potion` variants commented out (`evaluation.py:79-85`); multilingual (`bge-m3`) would drop a translation hop.

## 🟠 Generation & prompting

- **No streaming** — output guardrail buffers full text (`MedicalChatOrchestrator.swift:89-96`). Seconds of blank screen.
- **5–7 LLM round-trips per VI turn:** detect+refine → generate → fact-extract → translate-back → matches(→detect→confirm) (`ChatService.swift:106-107,232-296`; `LanguageValidationService.matches:267-297`).
- **Extra generation every turn** for session facts, parsed from prose JSON (`SessionFactExtractor.swift`). → use constrained/guided decoding.
- **No tool/function calling** — all string-prompt + regex + `<think>` stripping. Move fact/wound/triage to structured outputs.
- **One-size gen params** temp 0.3/topP 0.85/max 1024 even for classify/translate (`LLMService.swift:176`).
- **Crude context budget** — whitespace-split token count, greedy whole-chunk to 600 (`MedicalChatOrchestrator.swift:254-266`).

## 🟠 Guardrails (safety)

- **Substring/regex lists, English-only, brittle both ways.** FN: any paraphrase/VN self-harm slips; FP: `"act as a"` blocks "act as a caregiver", `"maximum dose"` blocks education (`GuardRailRules.swift:112-151`). Use classifier / Llama-Guard-style judge.
- **`isMedicalAdvice` = ~15 EN templates** (`OutputGuardRail.swift:139-149`); never sees VN output. Citation/dosage checks mostly bypassed.
- **PII = VN-only regex**, `\d{12}` nukes any 12-digit number; no name/DOB/MRN.

## 🟠 Metrics / Eval

- **QA metrics never run** — `answerer:none` → answer_similarity & faithfulness = 0.
- **`faithfulness` = naive cosine** (`metrics_qa.py:22-31`), not NLI/groundedness. Add RAGAS-style LLM-judge.
- **All 209 eval queries English** — VN pipeline/retrieval/answers unevaluated.
- **No latency/cost/per-tier/failure-slice metrics, no CI gate.**
- **`credibility_tier` barely used** (only +0.1 if top row tier-1). Tiers: 617 t1 / 621 t2 — could weight ranking.

## 🟠 Fine-tuning / model strategy (untapped)

- **No fine-tuning.** (a) LoRA/QLoRA the generator on corpus + VN medical QA; (b) **fine-tune embedder** on your 209 query→qrel pairs (biggest recall lever); (c) tiny domain/safety classifier to replace substring guards + LLM detector.
- **No distillation** from a large teacher (offline VN answers → on-device model).
- **Stock 4-bit only** — no AWQ/GPTQ compare, speculative decoding, or per-task model routing (1B for classify/translate, 4B for answer).

## 🟡 Vision / wound

- **Model thrash:** each photo unloads text model → loads 3B VLM → 1 inference → reload text model (2 multi-GB cycles) (`WoundAnalysisService.swift:63-101,153-177`). Keep one resident VLM.
- **Findings = free-text `KEY:value`**, string-parsed, no confidence/calibration.
- **Images hard-resized 512×512**, distorts wound geometry (`LLMService.swift:171`).

## 🟡 Dead code / waste

- **Kaggle anchor subsystem fully dead:** `initializeMedicalAnchors` never called; `medicalAnchors`/`medicalKeywords`/`patientIntentPatterns` never read. `MedicalAnchorLoader` + ZIPFoundation + Kaggle key = unused.
- **Duplicate corpus trees** at `Pipeline/` root *and* `Pipeline/data/` (parsed/cleaned/*_chunks).
- **`.venv` committed.**

## 🟡 Infra

- **No semantic/answer/embedding cache** — common Qs re-run full pipeline.
- **Single FULLMUTEX SQLite conn** serializes retrieval; no embed batching/warmup.
- **Observability = `print()` only**; no thumbs feedback capture for eval/finetune set.

## Priority (impact × effort)

1. Fix pooling (mean→CLS) + re-verify on-device recall.
2. Chunk max-cap + re-chunk 219 oversized; fix page numbers.
3. Cross-encoder reranker over top-15.
4. Re-run eval w/ shipped config + VN queries + answerer on + latency metric.
5. Collapse translation round-trips (multilingual embedder, guided decoding) + stream output.
6. Fine-tune embedder on qrels; classifier/judge guardrails.
7. Delete dead Kaggle/anchor code; de-dupe corpus trees.
