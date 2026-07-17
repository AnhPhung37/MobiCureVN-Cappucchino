# Chat Pipeline Architecture: Input → Output

This documents the full flow of a user's chat message (text and optional attached images) from the UI down to the on-device LLM and back, across the layers in `App/Frontend/VVM/Chat` and `App/Backend/Services`.

## Overview

```
ChatView (SwiftUI)
   │  user types message, optionally attaches photos (camera / library), taps send
   ▼
ChatViewModel                          [App/Frontend/VVM/Chat/ChatViewModel.swift]
   │  owns @Published messages/state, persists history (incl. image data)
   ▼
ChatService.processQuery               [App/Backend/Services/Chat/ChatService.swift]
   │  language detection → LLM refine → EMERGENCY DETECTION → Apple Translation (vi → en)
   │  … orchestrator (English-only) …
   │  LLM translation (en → vi) → validation → Apple Translation fallback
   ▼
MedicalChatOrchestrator.processQuery   [App/Backend/Services/GuardRail/MedicalChatOrchestrator.swift]
   │  Input GuardRail → RAG → Prompt Build → LLM (buffered) → Output GuardRail
   ▼
LLMService.stream                      [App/Backend/Services/LLMService/LLMService.swift]
   │  structured chat messages (+ images for vision models), selected model via MLX
   ▼
response delivered back up the chain to ChatView (buffered — one chunk, not token-by-token)
```

Two architectural decisions shape everything below:

- **The orchestrator (guardrails / RAG / LLM answer generation) only ever works in English.** All language handling — detection, refinement, translation in both directions, validation — lives one layer up in `ChatService`.
- **The response is buffered, not live-streamed.** `MedicalChatOrchestrator` accumulates the full LLM output so the Output GuardRail can validate/redact it before anything reaches the user, and `ChatService` needs the complete English text to translate it back. The UI receives the response as a single chunk.

## 1. UI layer — `ChatView` + `ChatViewModel`

`App/Frontend/VVM/Chat/ChatView.swift`, `ChatViewModel.swift`

- `ChatView` supports image attachments: camera capture (`CameraImagePicker`) and photo library. Before send, each `UIImage` is downscaled to ≤1024px and JPEG-encoded via `UIImage.attachmentJPEGData()` (`UIImage+Attachment.swift`) — raw 12MP camera photos would bloat history storage, and the vision model resizes to ~512px anyway.
- `ChatViewModel` holds `@Published var messages: [ChatMessage]`, `inputText`, `isLoading`, `processingState`, `backendStatus`, `downloadProgress`, plus grouped history (`sections`, `conversationSections`).
- `sendMessage(prompt:displayContent:attachedImageData:)` appends the user `ChatMessage` (with `imageData`), appends an empty assistant placeholder, then calls `chatService.processQuery(text, images:history:onSourcesRetrieved:)`. History passed to the pipeline is `messages.dropLast(2)` — the current turn travels separately, so leaving it in history would send it to the LLM twice.
- Retrieved RAG sources are captured via the `onSourcesRetrieved` callback (through a thread-safe `SourcesBox`) so citations can be attached to the finished assistant message without a second retrieval pass.
- Persists turns via `ChatHistoryRepository` (SQLite-backed, `AppConfig.chatHistoryRepository`), including image data, and supports multiple conversations (load/delete/switch by `conversationId`).
- Listens for `AppConfig.llmServiceDidChange` and rebuilds the orchestrator via `chatService.updateOrchestrator(...)` when the user switches models.
- Mirrors `ChatService.processingState` so the UI shows stage-specific labels: `.validatingLanguage` / `.refiningInput` / `.translatingInput` / `.generating` / `.translatingOutput`.
- Cancellation (Stop button, clear, conversation switch) cancels the streaming task; because the response arrives buffered at the end, a cancel usually means an empty placeholder, which is removed rather than finalized as an error.

## 2. `ChatService` — language handling + emergency detection

`App/Backend/Services/Chat/ChatService.swift`

Entry point: `processQuery(_ text: String, images: [Data], history: [ChatMessage], onSourcesRetrieved:) -> AsyncStream<String>`.

The design premise: the small on-device model never generates non-English *answers* — the medical pipeline only sees and produces English. Inbound conversion uses Apple's Translation framework; outbound, the LLM translates its own English response (noticeably more natural tone than Apple's literal output), verified by a validation pass with Apple Translation as the fallback.

1. **Language detection** — `LanguageValidationService.detect(text, using: AppConfig.llmService)` → `.vietnamese` / `.english` / `.mixed` / `.unsupported`. `.unsupported` short-circuits with a bilingual error message; no pipeline runs.
2. **LLM refine pass** (`.refiningInput`) — `LanguageValidationService.refine`: the LLM fixes typos and unifies code-switching, staying in the same language.
3. **Emergency detection** — `EmergencyDetector.detect` runs on the *refined original-language text*, before any translation or safety filter can interfere (its patterns cover Vietnamese and English phrasing directly). On a match, a canned emergency-redirect response is yielded and the pipeline stops — **the LLM is never invoked**.
4. **Translate input to English** (`.translatingInput`, skipped for English input) — `TranslationService.translateToEnglish` via Apple's on-device Translation framework. If the translation session isn't ready, this throws and the user gets a bilingual "processing error" message rather than silently degraded language quality.
5. **Orchestrator** (`.generating`) — `MedicalChatOrchestrator.processQuery` with the English query, attached images, and history (see §3). Output is accumulated into a single English response string.
6. **Translate response back** (`.translatingOutput`, skipped for English input) — `LanguageValidationService.translate`: the **LLM itself** translates the English response to the user's language.
7. **Validate the LLM translation** — a result shorter than ⅓ of the source is treated as truncated; otherwise `LanguageValidationService.matches` checks (script scan + LLM check) that it's complete and in the right language. On failure, fall back to `TranslationService.translateToVietnamese` (Apple Translation — literal in tone, but it doesn't leak foreign scripts). If Apple Translation is also unavailable, the imperfect LLM translation ships rather than erroring out the response.

Attached images bypass all text-only language steps untouched and are handed to the orchestrator alongside the English query.

`TranslationService` sessions (`viToEnSession`/`enToViSession`) are injected via `.translationTask()` SwiftUI modifiers on the persistent tab container and shared through `AppConfig.translationService`.

## 3. `MedicalChatOrchestrator` — guardrails, RAG, prompt assembly (English-only)

`App/Backend/Services/GuardRail/MedicalChatOrchestrator.swift`

By the time this runs, the query is always English. Emergency detection has already happened upstream. Pipeline inside `processQuery`:

1. **Input GuardRail** (`InputGuardRail.validate`) — dangerous request patterns (hard block), prompt injection/jailbreak patterns (hard block), PII detection + masking (masks, doesn't block), and a medical-relevance domain filter (fast keyword/intent match, then `NLEmbedding` cosine similarity against medical anchor phrases). Guardrails run on the query **text** only; images ride along unchecked.
2. **RAG retrieval** (`RAGService.process`) — runs on the sanitized English query; `QueryRefiner` refines it, `SQLiteRetriever` does FTS5 lookup against `vectorstore.db`, returning `RetrievedContext` (chunks, sources, confidence score). Sources are surfaced immediately via `onSourcesRetrieved` for UI citations.
3. **Prompt assembly** (`buildEnrichedPrompt`) —
   - An English-only `LANGUAGE:` instruction stated three times (top, mid-constraints, final "REMINDER" after the RAG context) — a deliberate sandwich against recency bias.
   - Role/scope constraints (informational only, no diagnosis, cite sources, no confident dosages, emergency redirect, consult-a-doctor disclaimer).
   - RAG context chunks token-budgeted to ~600 tokens (`contextTokenBudget`) plus a formatted source list and confidence score.
   - When retrieval found nothing, an explicit note permits answering common health/lifestyle questions from general knowledge (labeled as general guidance) while still declining clearly off-topic ones.
   - Conversation history trimmed to the last 4 turns / 8 messages (`maxHistoryTurns`) to bound prefill time on a ~3–4B model.
4. **LLM generation** (`LLMService.stream`, see §4) — **fully buffered**: the Output GuardRail needs the complete response (hallucination detection, dosage detection, citation enforcement can replace it outright), so no token can safely be shown earlier. There is no language-verification/retry step at this layer anymore — the orchestrator only ever sees and produces English.
5. **Output GuardRail** (`OutputGuardRail.validate`) — citation enforcement, low-confidence caution banner, hallucination-indicator redaction, unsafe-dosage replacement. The (possibly filtered/annotated) response is yielded as one chunk.

Consumer cancellation propagates down (`continuation.onTermination` → task cancel) so tapping Stop actually halts MLX generation instead of letting it run to completion in the background.

## 4. `LLMService` — model execution

`App/Backend/Services/LLMService/LLMService.swift`

- Runs the user-selected model from `ModelCatalog` locally via **MLX Swift** (`MLXLLM`/`MLXVLM`/`MLXLMCommon`), with a mock/placeholder fallback when the model isn't available, `useMock` is set, or the build lacks the MLX packages (simulator/Mac). Default model: **Qwen 3.5 4B 4-bit (vision)**; alternatives include Qwen 2.5 3B, Llama 3.2 3B, Phi 3.5 Mini, Gemma 3 1B, and Qwen 2.5 VL 3B/7B. Model selection, download (`ModelManager`), and hot-swapping live in `AppConfig` — switching posts `llmServiceDidChange`, which `ChatViewModel` uses to rebuild the orchestrator.
- **Vision support**: `isVisionModel` is decided once at init from the model export's `config.json` `model_type` (matched against the types `VLMModelFactory` registers). Vision models load through `VLMModelFactory`, text-only through `LLMModelFactory`. For text-only models, attached images are dropped before prompt building (attaching them would make `prepare()` throw).
- **Structured chat, not a flat prompt**: `buildChat(system:history:user:images:)` assembles real `[Chat.Message]` roles (`.system` / `.user` / `.assistant`) and passes them via `UserInput(chat:)`, so `container.prepare` applies the model's own chat template (e.g. Qwen's `<|im_start|>` format) through the tokenizer. This replaced the earlier hand-rolled `System:/User:` flat string, which bypassed the template and measurably degraded output quality.
- Images attach to their user turns per the multimodal chat convention — the current turn's images to the final user message, and history user turns re-attach their own persisted `imageData` (only when talking to a vision model), so follow-up questions about an earlier photo still work. Image bytes are decoded to `UserInput.Image.ciImage`; `input.processing.resize = 512×512` bounds vision prefill cost (a full-resolution photo would expand into thousands of image tokens).
- `additionalContext: ["enable_thinking": false]` disables Qwen 3+ hybrid-reasoning thinking mode (which would burn the token budget on a `<think>` preamble and leak it into the chat); templates without the variable ignore it.
- `GenerateParameters(maxTokens: 1024, temperature: 0.3, topP: 0.85)` — deliberately low temperature/topP since deterministic, on-language output matters more than lexical variety, and higher values let a small multilingual model drift into English/Chinese/Thai mid-reply.
- Thread safety under Swift 6 strict concurrency: `OSAllocatedUnfairLock` guards the model container between `initializeModel()`/`unload()` and the detached generation task.

> **Memory management** (MLX cache limits, memory-pressure unloading, model swapping) is documented separately in [`OOM-Memory-Management.md`](./OOM-Memory-Management.md).

## Key design properties

- **One language inside the medical pipeline**: guardrails, RAG, prompt, and generation all operate in English only. This removed the old language-verification-and-retry loop from the orchestrator — language conversion is now an explicit, testable layer in `ChatService` with a deterministic fallback (Apple Translation) instead of a re-prompt.
- **Best tool per translation direction**: inbound uses Apple Translation (reliable, literal is fine for a query); outbound uses the LLM (natural tone) but is validated for completeness and script, with Apple Translation as the safety net when the small model leaks foreign scripts or truncates.
- **Emergency detection runs first and in the user's own language** — before refinement artifacts, translation, or any safety filter can interfere — and bypasses the LLM entirely, trading generative flexibility for guaranteed, reviewed emergency guidance.
- **Safety checks are layered and ordered by cost**: cheap keyword/regex checks run before `NLEmbedding` similarity or LLM passes, and hard blocks (dangerous requests, injection) short-circuit before any retrieval or generation.
- **Buffered delivery is a deliberate trade**: the user waits longer for the first visible text, but the Output GuardRail can inspect and redact the complete response, and the back-translation step needs the whole English text anyway.
- **Images are multimodal passengers**: text guardrails, RAG, and translation ignore them; they attach to chat turns only when the loaded model actually supports vision, and are downscaled twice (≤1024px at capture for storage, ~512px at prefill for token cost).
