# Chat Pipeline Architecture: Input → Output

This documents the full flow of a user's chat message from the UI down to the on-device LLM and back, across the layers in `App/Frontend/VVM/Chat` and `App/Backend/Services`.

## Overview

```
ChatView (SwiftUI)
   │  user types message, taps send
   ▼
ChatViewModel                          [App/Frontend/VVM/Chat/ChatViewModel.swift]
   │  owns @Published messages/state, persists history
   ▼
ChatService.processQuery               [App/Backend/Services/Chat/ChatService.swift]
   │  language detection → branch: English pipeline vs Vietnamese/mixed pipeline
   ▼
TranslationService (vi → en, RAG-only) [App/Backend/Services/Translation/TranslationService.swift]
   ▼
MedicalChatOrchestrator.processQuery   [App/Backend/Services/GuardRail/MedicalChatOrchestrator.swift]
   │  Input GuardRail → Emergency Detection → RAG → Prompt Build → LLM → verify language → Output GuardRail
   ▼
LLMService.stream                      [App/Backend/Services/LLMService/LLMService.swift]
   │  builds flat prompt, runs Qwen2.5-7B via MLX
   ▼
tokens streamed back up through the same chain to ChatView
```

## 1. UI layer — `ChatViewModel`

`App/Frontend/VVM/Chat/ChatViewModel.swift`

- Holds `@Published var messages: [ChatMessage]`, `inputText`, `isLoading`, `processingState`, `backendStatus`.
- On send, appends the user's `ChatMessage` to `messages`, calls `chatService.processQuery(text, history:)`, and streams tokens into a live-updating assistant `ChatMessage`.
- Persists conversation turns via `ChatHistoryRepository` (SQLite-backed, `AppConfig.chatHistoryRepository`).
- Mirrors `ChatService.processingState` (`.idle` / `.validatingLanguage` / `.translatingInput` / `.generating`) so the UI can show stage-specific indicators (e.g. "Translating…", "Thinking…").

## 2. `ChatService` — language routing

`App/Backend/Services/Chat/ChatService.swift`

Entry point: `processQuery(_ text: String, history: [ChatMessage]) -> AsyncStream<String>`.

1. **Language detection** (synchronous): `LanguageValidationService.detect(text)` → `.vietnamese` / `.english` / `.mixed` / `.unsupported`.
   - `.unsupported` short-circuits immediately with a bilingual error message (`LanguageValidationService.unsupportedErrorMessage`) — no LLM call.
2. **Branch on `detected.requiresTranslation`** (true for `.vietnamese`/`.mixed`):
   - **`runViToViPipeline`**: translates the query **vi → en** via `TranslationService.translateToEnglish` (Apple's on-device `Translation` framework, iOS 17.4+) — this English text is used **only** to improve RAG document retrieval, never sent to the user. The **original Vietnamese text** is passed to the orchestrator as the actual query, with `responseLanguage: .vietnamese`.
   - **`runEnglishPipeline`**: passes the English text straight through, `responseLanguage: .english`.
3. Both branches call `MedicalChatOrchestrator.processQuery(...)` and forward its token stream upward, tracking `processingState` at each stage.

`TranslationService` sessions (`viToEnSession`/`enToViSession`) are injected once via `.translationTask()` SwiftUI modifiers on `HomeView` (the persistent tab container) and shared through `AppConfig.translationService`. If a session isn't ready, `translateToEnglish` throws and `ChatService` yields a bilingual "processing error" message rather than silently degrading language quality.

## 3. `MedicalChatOrchestrator` — guardrails, RAG, prompt assembly

`App/Backend/Services/GuardRail/MedicalChatOrchestrator.swift`

Pipeline inside `processQuery`:

1. **Input GuardRail** (`InputGuardRail.validate`) — 4 rule groups, in priority order:
   1. Dangerous request patterns (self-harm, violence, illegal) → hard block.
   2. Prompt injection / jailbreak patterns → hard block.
   3. PII detection + masking (regex-based; masks before continuing, doesn't block).
   4. Domain filter — medical relevance, checked via fast keyword/intent match first, then `NLEmbedding` cosine-similarity against medical anchor phrases (English-space; uses the translated `ragQuery` when available so Vietnamese input is compared correctly) → blocks off-topic queries.
2. **Emergency detection** (`EmergencyDetector.detect`) — keyword-pattern match against `GuardRailRules.emergencySymptomPatterns`. If matched, immediately yields a canned emergency-redirect response and **skips the LLM entirely**.
3. **RAG retrieval** (`RAGService.process`) — `QueryRefiner` refines the query, `SQLiteRetriever` does FTS5 lookup against `vectorstore.db`, returning `RetrievedContext` (chunks, sources, confidence score). Uses the English `ragQuery` when the input was Vietnamese.
4. **Prompt assembly** (`buildEnrichedPrompt`) — builds the system prompt:
   - A `LANGUAGE:` instruction stated three times (top, mid-constraints, and a final "REMINDER" after the RAG context) — a deliberate sandwich to counter recency bias from English-language RAG context sitting just before the reminder.
   - Role/scope constraints (informational only, no diagnosis, cite sources, no confident dosages, emergency redirect, consult-a-doctor disclaimer).
   - RAG context chunks (token-budgeted to ~600 tokens) and source list.
   - Conversation history trimmed to the last 4 turns (8 messages) to bound prompt length.
5. **LLM generation** (`LLMService.stream`, see §4) — **fully buffered, not live-streamed**, specifically so the response's language can be verified before any tokens reach the user.
6. **Language verification + one retry** (`languageMatches` using the same `LanguageValidationService.detect`) — if the buffered response doesn't match `responseLanguage`, the orchestrator re-prompts once with an explicit "your previous answer was NOT in the required language, rewrite it" correction. If the retry still fails, it falls back to the original (wrong-language) response rather than looping further.
7. **Output GuardRail** (`OutputGuardRail.validate`) — checked in order:
   1. Citation enforcement — medical-advice-shaped responses without citations get a citation reminder appended.
   2. Confidence threshold — advice given with low RAG confidence gets a caution banner prepended.
   3. Hallucination detection — regex indicators of overconfident/fabricated claims → offending spans replaced with `[removed: unverified claim]`.
   4. Unsafe dosage detection — regex patterns for specific dosages → replaced with a "consult a healthcare provider" placeholder.
8. Final (possibly filtered/annotated) response is yielded to the stream.

## 4. `LLMService` — model execution

`App/Backend/Services/LLMService/LLMService.swift`

- Wraps Qwen2.5-7B-Instruct running locally via **MLX Swift** (`MLXLLM`/`MLXLMCommon`), with a mock/placeholder fallback when the model isn't available or `useMock` is set.
- `buildPrompt(system:history:user:)` currently flattens everything into one string with `System:` / `User:` / `Assistant:` text labels (see note below).
- `generate(prompt:)` wraps that string in `UserInput(prompt:)` and calls `container.prepare(input:)` → `container.generate(...)`, streaming `.chunk(text)` events with `GenerateParameters(maxTokens: 1024, temperature: 0.3, topP: 0.85)` — deliberately low temperature/topP since this is a medical assistant where on-language, deterministic output matters more than lexical variety.

> **Known issue (see `fix/translation-service-errors` investigation):** `UserInput(prompt:)` wraps the entire flattened text as a single `.chat([.user(...)])` message with no real system role. `container.prepare` applies Qwen's actual ChatML template on top of that single user turn, so the model never sees a proper `<|im_start|>system` block — the strong "respond only in Vietnamese" instruction ends up as plain text inside a user turn instead of a system-level directive, which is a likely contributor to occasional English/Chinese/Thai drift. Planned fix: build `[Chat.Message]` with real `.system`/`.user`/`.assistant` roles and use `UserInput(chat:)` instead.

> **Memory management** (stream buffering, MLX cache limits, memory-pressure handling) is documented separately in [`OOM-Memory-Management.md`](./OOM-Memory-Management.md).

## Key design properties

- **Language integrity is enforced twice**: once implicitly via prompt instructions, once explicitly via post-hoc detection + single retry — because a wrong-language answer can't be un-sent once streamed.
- **Translation is one-directional and RAG-only**: Vietnamese user input is never translated to English for the LLM call itself, only for retrieval; the LLM answers in Vietnamese directly, avoiding a second (post-answer) translation pass that would add latency and translation-fidelity risk.
- **Safety checks are layered and ordered by cost**: cheap keyword/regex checks run before expensive `NLEmbedding` similarity or a second LLM pass, and hard safety blocks (dangerous requests, injection) short-circuit before any retrieval or generation happens.
- **Emergency queries bypass the LLM entirely**, trading generative flexibility for guaranteed, reviewed emergency guidance.
