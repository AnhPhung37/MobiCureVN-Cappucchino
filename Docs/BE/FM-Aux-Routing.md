# Routing post-answer extraction to the on-device Foundation Model

Branch `final0.1-fm-aux-routing`. `AppConfig.utilityLLMService` existed with zero call sites: every
auxiliary LLM pass ran on the same MLX `ModelContainer` as the chat model, including two that run
*after* the answer is already delivered. This branch routes those two to Apple's system model when
it's available, so they stop holding the one resident container the next message needs.

## The queue this removes

MLX serializes every generation through a single `ModelContainer` (see `MedicalChatOrchestrator`'s
own comment on this in `ChatService.swift`). Steps 6 and 7 of the pipeline — `SessionFactExtractor`
and `ProfileUpdateExtractor`, both short JSON-extraction passes — run after `.final` is yielded, so
they never delay the CURRENT answer. But they still hold the container, so the user's NEXT message
queues behind them even though nothing about it depends on their result. On a phone or tablet where
the fastest available model is 3–4B parameters, that queued generation is not free.

## What changed

`App/Backend/Services/GuardRail/MedicalChatOrchestrator.swift` — steps 6 and 7 now call
`factExtractor.extract` / `profileUpdateExtractor.extract` with `AppConfig.utilityLLMService`
instead of the resident MLX `llmService`. That property already existed
(`App/Backend/Configs/AppConfig.swift`) and already does the fallback: it prefers
`FoundationModelsService` when `#available(iOS 26.0, *)` and `SystemLanguageModel.default` reports
available, and falls back to the same MLX `llmService` otherwise — so a device without Apple
Intelligence sees no behavior change at all.

`App/Backend/Services/LLMService/FoundationModelsService.swift` — previously ignored
`LLMRequest.options` entirely and always used the framework's own sampling default. Both
extractors ask for `.extraction` (temperature 0, a small token ceiling) specifically because
unbounded, creative decoding produces prose instead of parseable JSON — silently dropping that on
the new code path would have defeated half the point of routing to it. `generationOptions(for:)`
now translates the app's `GenerationOptions` into `FoundationModels.GenerationOptions`: temperature
0 becomes `.samplingMode: .greedy` (the framework expresses "no randomness" as a sampling mode, not
`temperature: 0`, which still samples), and `maxTokens` maps to `maximumResponseTokens`. `topP` has
no equivalent in this framework and is dropped.

## Why detect/refine were left alone

`ChatService`'s language `detect`/`refine` calls (the ones on the message's critical path, before
the answer starts) still use `AppConfig.llmService` directly and are **not** touched here. They run
on the RAW, original-language text — which for a meaningful share of turns is Vietnamese — before
the pipeline knows what language it's looking at. Whether Apple's on-device model handles
Vietnamese well enough for a language-detection/rewrite pass to move here safely is not something
this session could verify (no device, no way to probe `SystemLanguageModel`'s supported-locale
surface from this machine). Routing a step that runs on Vietnamese input to an unverified backend
risks the app's core bilingual behavior for a latency win on a step that already has a fast path
(`LanguageValidationService`'s diacritic-density short-circuit skips the LLM entirely for most
turns). Steps 6/7 carry no such risk: `sanitizedQuery` is documented and structurally guaranteed
English by the time the orchestrator sees it (ChatService translates upstream). Confirming
Vietnamese support and moving detect/refine is a natural follow-up, not done here.

## Failure mode

Apple's system model carries its own content-safety guardrails, which can refuse innocuous health
content (an allergy, a wound location) more readily than the MLX chat model does. Both extractors
already parse a failed or empty reply as "no facts" (`SessionFactExtractor.parse` /
`ProfileUpdateExtractor.parse`, both fail-closed on unparseable output) — a refusal here costs
nothing beyond a missed extraction for that turn, identical in effect to a generation that timed
out or a task that was cancelled. No new failure mode, only a new source of the same one.

## Not verified here

No Swift was compiled on this branch's machine (Linux). Before merging:

1. Build on Mac/Xcode; `FoundationModelsGenerationOptionsTests` needs a target that supports
   iOS 26 to actually run its assertions (they no-op under `#available` otherwise).
2. On a device/simulator with Apple Intelligence on, have a multi-turn conversation that states a
   durable fact ("I'm 62, allergic to penicillin") and confirm: (a) the fact still appears via
   `SessionFactExtractor`/profile proposal cards, (b) the log line for step 6/7 shows the pass ran
   without stalling the next message's stage-1 log entry.
3. Toggle Apple Intelligence off (or run pre-iOS 26) and confirm steps 6/7 still work exactly as
   before — `utilityLLMService` should fall back to `llmService` transparently.
4. Watch for the system model refusing a benign medical fact in practice; if refusals are frequent
   enough to matter, that is the point to reconsider using it for this pass rather than continuing
   past this branch's measurement-free assessment.

## Tests

`MobiCureVNTests/FoundationModelsGenerationOptionsTests.swift` (3): the deterministic presets map
to greedy sampling (not `temperature: 0`), an answering-style preset keeps its temperature, and the
token ceiling survives translation either way.
