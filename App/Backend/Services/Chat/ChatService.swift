import Foundation
import Combine

// MARK: - Processing State

// Describes which stage of the translation+generation pipeline is active.
// Drives the status indicator in ChatView.
enum ChatProcessingState: Equatable {
    case idle
    case validatingLanguage
    case refiningInput      // LLM fixes typos/code-switching, same language
    case translatingInput   // original language → en (Apple Translation)
    case generating         // LLM is running (always in English)
    case translatingOutput  // en → original language (LLM; Apple Translation fallback)
}

// MARK: - ChatService

// Top-level orchestrator: language validation → refine → translate in → LLM → verify → stream.
// Wraps MedicalChatOrchestrator so the existing guardrail / RAG / LLM pipeline
// is unchanged; language handling is layered on top.
//
// The medical pipeline (input guardrail, RAG retrieval, retrieved context) always works in
// English — that is where the corpus and the rules live. The ANSWER, however, is generated
// directly in the user's language rather than written in English and translated afterwards.
// That second full decode used to cost more than producing the answer itself, and removing it
// is the single largest latency saving available here.
//   1. Detect the input's language and run the "refine" pass. Both consume only the original
//      text, so they are issued together via `async let` — though note MLX serialises all
//      generation through one model container, so this queues rather than truly overlapping.
//   2. LLM "refine" pass: fix typos and unify code-switching, staying in the same language.
//      Gated by `needsRefinement` — most turns are already clean and skip the LLM entirely.
//   3. Emergency detection on the refined original-language text.
//   4. Apple Translation: refined input → English (skipped if already English), so guardrails
//      and retrieval see English.
//   5. Orchestrator generates the answer in the user's language (`responseLanguage`).
//   6. Deterministic drift check: script scan + Vietnamese density + English-run detection. No
//      LLM call. If the model drifted fully into English, Apple Translation repairs it.
//
// NOTE: because there is no longer an English original sitting behind a Vietnamese answer, a
// partially-drifted response (code-switched, or with a stray foreign-script word) can no longer
// be repaired by re-translating — it is passed through and logged instead. Only a full drift
// into English has a clean repair path.
//
// NOTE: the ANSWER is still buffered — MedicalChatOrchestrator holds the full LLM output so the
// output guardrail can validate/redact it before delivery, and the drift check below needs the
// whole text too. What the stream carries is therefore two different things (see
// ChatStreamEvent): `.preview` snapshots of the raw decode, forwarded straight through so the UI
// can show the reply being written, and exactly one `.final` carrying the validated answer that
// replaces them. Previews are never verified, translated, or persisted.
@MainActor
final class ChatService: ObservableObject {

    @Published private(set) var processingState: ChatProcessingState = .idle

    private var orchestrator: MedicalChatOrchestrator
    private let languageValidator: LanguageValidationService
    private let translationService: TranslationService
    private let emergencyDetector: EmergencyDetector
    private let nameGuard: NameGuard

    init(
        orchestrator: MedicalChatOrchestrator,
        languageValidator: LanguageValidationService = LanguageValidationService(),
        translationService: TranslationService,
        emergencyDetector: EmergencyDetector = EmergencyDetector(),
        nameGuard: NameGuard = NameGuard()
    ) {
        self.orchestrator = orchestrator
        self.languageValidator = languageValidator
        self.translationService = translationService
        self.emergencyDetector = emergencyDetector
        self.nameGuard = nameGuard
    }

    // Called when AppConfig swaps the underlying LLM service.
    func updateOrchestrator(_ newOrchestrator: MedicalChatOrchestrator) {
        orchestrator = newOrchestrator
    }

    // MARK: - Main Pipeline

    /// - Parameter images: encoded images attached to this user turn. They bypass the
    ///   text-only language steps (refine/translate) untouched and are handed to the
    ///   orchestrator alongside the English query, per the multimodal chat convention.
    func processQuery(
        _ text: String,
        images: [Data] = [],
        history: [ChatMessage],
        conversationId: UUID,
        onSourcesRetrieved: (@Sendable ([MedicalSource]) -> Void)? = nil,
        onProfileUpdateProposed: (@Sendable ([ProposedProfileUpdate]) -> Void)? = nil
    ) -> AsyncStream<String> {
        processingState = .validatingLanguage

        // Newest-only, for the same reason as the orchestrator's stream: a dropped preview
        // costs nothing (the next snapshot supersedes it) and the single `.final` is yielded
        // last, so it can never be the element discarded.
        return AsyncStream<ChatStreamEvent>(bufferingPolicy: .bufferingNewest(1)) { [weak self] continuation in
            guard let self else { continuation.finish(); return }

            let innerTask = Task { @MainActor [weak self] in
                guard let self else { continuation.finish(); return }

                // Stage-timing: mirrors MedicalChatOrchestrator's ⏱️ logs so a Vietnamese turn's
                // full cost is visible — the language passes here (detect/refine/translate/verify)
                // are LLM round-trips that the orchestrator's own timing can't see. Monotonic clock.
                let pipelineStart = DispatchTime.now()
                var stageMark = pipelineStart

                let flow = ChatFlowLog()

                // Pin the user's name from the RAW input, before refine can mangle it (the
                // observed "I'm hanh" → "Haven't" corruption). The name is captured exactly as
                // typed and protected end-to-end so no LLM transform re-accents or rewrites it.
                let pinnedName = self.nameGuard.detectName(in: text)

                // detect and refine both consume only the original text and are independent, so
                // they're issued together via `async let`. Note this does NOT actually run them
                // in parallel: MLX routes every generation through one ModelContainer guarded by
                // a serial async mutex, so the two calls queue. The real saving comes from
                // `needsRefinement` skipping the refine call outright on clean input, and from
                // `detect` short-circuiting on diacritic density — most turns make zero LLM
                // calls here. The UI shows "validating language" for this combined step.
                // Refine runs on name-protected text so the pinned name is never touched.
                let llmService = AppConfig.llmService
                let protectedInput = self.nameGuard.protect(text, name: pinnedName)
                async let detectedResult = self.languageValidator.detect(text, using: llmService)
                async let refinedResult = self.languageValidator.refine(protectedInput, using: llmService)

                let detected = await detectedResult
                flow.input(text, language: Self.languageTag(detected))
                if let pinnedName { flow.stage("name pinned", pinnedName) }

                // The language gate classifies TEXT only. An image-bearing turn often carries
                // just a placeholder caption ("Image attached") or a short note, which the
                // small on-device classifier tends to label "other" → .unsupported — wrongly
                // rejecting the turn before the vision model ever sees the image. When images
                // are attached, never refuse on language grounds: fall back to a supported
                // language (Vietnamese if the caption shows any Vietnamese signal, else
                // English) so the image still reaches the pipeline.
                let effectiveDetected: DetectedLanguage
                // Set only by the unsupported-recovery path below, where a forced refine
                // produced a cleaner input than the (skipped) gated one. Supersedes
                // `refinedResult` downstream.
                var recoveredText: String?

                if case .unsupported = detected, !images.isEmpty {
                    effectiveDetected = self.languageValidator.vietnameseDensity(text) > 0
                        ? .vietnamese
                        : .english
                } else if case .unsupported = detected {
                    // Discard the concurrently-running refine result: either the gate skipped
                    // it (so it's just the input back) or it ran and still didn't help.
                    _ = await refinedResult

                    if let salvaged = await self.recoverUnsupported(
                        rawText: text,
                        protectedInput: protectedInput,
                        pinnedName: pinnedName,
                        llmService: llmService,
                        flow: flow
                    ) {
                        effectiveDetected = salvaged.language
                        recoveredText = salvaged.text
                    } else {
                        // Text-only turn in a genuinely unsupported language: refuse as before.
                        Self.logStage("TOTAL per-message (unsupported)", since: pipelineStart)
                        flow.end("unsupported language")
                        self.processingState = .idle
                        continuation.yield(.final(LanguageValidationService.unsupportedErrorMessage))
                        continuation.finish()
                        return
                    }
                } else {
                    effectiveDetected = detected
                }

                // Restore the pinned name into the refined text, undoing the protective
                // sentinel so downstream stages see natural text with the correct spelling.
                // The recovery path has already restored its own text.
                let refinedText: String
                if let recoveredText {
                    refinedText = recoveredText
                } else {
                    refinedText = self.nameGuard.restore(await refinedResult, name: pinnedName)
                }
                // detect + refine ran concurrently, so this single elapsed covers both LLM
                // passes (the longer of the two dominates), measured from pipeline start.
                stageMark = Self.logStage("A · detect+refine (LLM, concurrent)", since: stageMark)
                flow.stage("refine", refinedText, tag: Self.languageTag(effectiveDetected))

                do {
                    try await self.runPipeline(
                        refinedText: refinedText,
                        images: images,
                        detectedLanguage: effectiveDetected,
                        pinnedName: pinnedName,
                        history: history,
                        conversationId: conversationId,
                        onSourcesRetrieved: onSourcesRetrieved,
                        onProfileUpdateProposed: onProfileUpdateProposed,
                        flow: flow,
                        pipelineStart: pipelineStart,
                        sinceMark: stageMark,
                        continuation: continuation
                    )
                } catch {
                    flow.end("error: \(error.localizedDescription)")
                    let msg = "Lỗi xử lý: \(error.localizedDescription)\n" +
                              "Processing error: \(error.localizedDescription)"
                    continuation.yield(.final(msg))
                }

                self.processingState = .idle
                continuation.finish()
            }

            // Cancel the inner task when the consumer stops reading.
            continuation.onTermination = { _ in
                innerTask.cancel()
            }
        }
    }

    // MARK: - Unsupported-language recovery

    /// Last-chance rescue before refusing a turn as an unsupported language.
    ///
    /// `needsRefinement` is deterministic and can only see signals the text actually carries.
    /// Heavily-mangled telex — "Tui themf traf suxwa" for "Tôi thèm trà sữa" — carries none:
    /// no diacritics, no recognisable Vietnamese function words, so density reads 0 and the gate
    /// concludes "plain English, nothing to unify". That is exactly backwards; this is the input
    /// class refine exists for. The classifier then sees a word salad and answers "other", and
    /// the user gets a refusal for a perfectly ordinary Vietnamese sentence.
    ///
    /// Rather than keep widening the gate's heuristics until they catch every mangling, recover
    /// here: run refine once with the gate bypassed, then re-detect. This spends LLM time only on
    /// the rare rejection path — where the alternative is refusing the user outright — instead of
    /// requiring the gate to be perfect on every turn.
    ///
    /// Returns the refined text and its language, or `nil` when re-detection still says
    /// unsupported (a genuinely unsupported language, which refine cannot and should not fix).
    private func recoverUnsupported(
        rawText: String,
        protectedInput: String,
        pinnedName: String?,
        llmService: LLMServiceProtocol,
        flow: ChatFlowLog
    ) async -> (text: String, language: DetectedLanguage)? {
        // If the gate already let refine run, the LLM has had its shot at this text and the
        // verdict stands — retrying would just buy the same answer for another round-trip.
        guard !languageValidator.needsRefinement(rawText) else {
            flow.note("recover", "skipped (refine already ran)")
            return nil
        }

        let mark = DispatchTime.now()
        processingState = .refiningInput

        let forced = nameGuard.restore(
            await languageValidator.refine(protectedInput, using: llmService, force: true),
            name: pinnedName
        )

        guard !Task.isCancelled else { return nil }

        // No usable rewrite: refine returned the input essentially unchanged (including its own
        // degenerate-output fallback), so re-detecting would ask the same question twice.
        guard forced.trimmingCharacters(in: .whitespacesAndNewlines)
                != rawText.trimmingCharacters(in: .whitespacesAndNewlines) else {
            Self.logStage("A2 · forced refine (no change)", since: mark)
            flow.note("recover", "refine returned input unchanged")
            return nil
        }

        let redetected = await languageValidator.detect(forced, using: llmService)
        Self.logStage("A2 · forced refine + re-detect (LLM)", since: mark)

        if case .unsupported = redetected {
            flow.note("recover", "still unsupported after refine")
            return nil
        }

        flow.stage("recover", forced, tag: Self.languageTag(redetected))
        return (forced, redetected)
    }

    // MARK: - Pipeline

    // Unified pipeline: LLM refine (same language) → translate to English (if needed) →
    // orchestrator always in English → translate back to original language (if needed) →
    // LLM validation with LLM-translate fallback on mismatch.
    private func runPipeline(
        refinedText: String,
        images: [Data],
        detectedLanguage: DetectedLanguage,
        pinnedName: String?,
        history: [ChatMessage],
        conversationId: UUID,
        onSourcesRetrieved: (@Sendable ([MedicalSource]) -> Void)?,
        onProfileUpdateProposed: (@Sendable ([ProposedProfileUpdate]) -> Void)?,
        flow: ChatFlowLog,
        pipelineStart: DispatchTime,
        sinceMark: DispatchTime,
        continuation: AsyncStream<ChatStreamEvent>.Continuation
    ) async throws {
        var stageMark = sinceMark

        // Step 1: LLM refine — fix typos and unify code-switching, same language. This now
        // runs concurrently with detect (in processQuery) and is already complete here; we
        // still surface the .refiningInput state so the UI status label is unchanged.
        processingState = .refiningInput

        guard !Task.isCancelled else { return }

        // Step 2: Emergency Detection — a user describing a crisis (chest pain, "I want to
        // die", etc.) must reach the emergency template before any translation or safety
        // filter can interfere. Runs on the refined original-language text since
        // EmergencyDetector's patterns cover both Vietnamese and English phrasing directly.
        let emergency = emergencyDetector.detect(query: refinedText)
        if emergency.isEmergency {
            if let response = emergency.recommendation {
                flow.stage("emergency", response, tag: Self.languageTag(detectedLanguage))
                flow.output(response, language: Self.languageTag(detectedLanguage))
                continuation.yield(.final(response))
            } else {
                flow.end("emergency (no template)")
            }
            Self.logStage("TOTAL per-message (emergency)", since: pipelineStart)
            return
        }

        // Step 3: translate the refined input to English so the orchestrator only ever
        // has to work in one language. The name is protected across translation too, so
        // Apple Translation can't localise/re-accent it on the way in.
        let englishQuery: String
        if detectedLanguage.requiresTranslation {
            processingState = .translatingInput
            let protectedInput = nameGuard.protect(refinedText, name: pinnedName)
            let translatedIn = try await translationService.translateToEnglish(protectedInput)
            englishQuery = nameGuard.restore(translatedIn, name: pinnedName)
            stageMark = Self.logStage("B · translate→en (Apple)", since: stageMark)
            flow.stage("translate→en", englishQuery, tag: "en")
        } else {
            englishQuery = refinedText
        }

        guard !Task.isCancelled else { return }

        // Step 4: the orchestrator generates directly in the user's language. Guardrails and
        // RAG still run in English on `englishQuery`; only the answer changes language.
        //
        // Draft snapshots are forwarded to the caller as they arrive so the reply can be watched
        // being written; the validated answer arrives as a single `.final` at the end (see the
        // class-level NOTE). Forwarding the drafts untouched is what makes them cheap — and it
        // is only safe to show them at all because generation is now native: the drafts are
        // already in the user's language rather than English awaiting a translation pass.
        processingState = .generating
        var generatedResponse = ""
        for await event in orchestrator.processQuery(
            englishQuery,
            images: images,
            conversationHistory: history,
            conversationId: conversationId,
            onSourcesRetrieved: onSourcesRetrieved,
            onProfileUpdateProposed: onProfileUpdateProposed
            responseLanguage: detectedLanguage
        ) {
            guard !Task.isCancelled else { return }
            switch event {
            case .preview(let draft):
                continuation.yield(.preview(draft))
            case .final(let answer):
                generatedResponse = answer
            }
        }
        // Whole orchestrator round-trip (its own ⏱️ lines break this down further internally).
        stageMark = Self.logStage("C · generation (orchestrator)", since: stageMark)
        flow.stage("generate", generatedResponse, tag: Self.languageTag(detectedLanguage))

        guard !Task.isCancelled else { return }

        // Step 5: confirm the answer really came out in the requested language.
        //
        // There is no translation pass here any more. Generating in English and then having the
        // LLM re-decode the whole answer in Vietnamese cost more than writing the answer in the
        // first place — it was the single largest item in the per-message budget. The model now
        // writes Vietnamese directly and this step only has to catch drift.
        //
        // The check is deterministic (script scan + Vietnamese density + English-run detection),
        // so the happy path costs nothing at all rather than an LLM verification round-trip.
        var finalResponse = generatedResponse
        if detectedLanguage.requiresTranslation {
            let check = languageValidator.checkGeneratedLanguage(
                generatedResponse, expected: detectedLanguage
            )
            switch check {
            case .ok:
                flow.note("verify", "ok (native \(Self.languageTag(detectedLanguage)) generation)")

            case .wrongLanguage:
                // The model ignored the language instruction and answered in English — the one
                // drift case with a clean repair, since the text really is English. Apple
                // Translation handles it in about a tenth of a second. The name is protected
                // across the call so it can't be re-accented ("Hanh" → "Hạnh").
                processingState = .translatingOutput
                flow.note("verify", "fallback → Apple Translation (\(check.reason))")
                if let appleOut = try? await translationService.translateToVietnamese(
                    nameGuard.protect(generatedResponse, name: pinnedName)
                ) {
                    finalResponse = nameGuard.restore(appleOut, name: pinnedName)
                }

            case .codeSwitched, .foreignScript:
                // Predominantly correct Vietnamese with a leaked run of English or a stray CJK
                // word. Deliberately NOT repaired: unlike the case above there is no English
                // original to translate from, and pushing mostly-Vietnamese text through the
                // en→vi session would garble the Vietnamese that is already correct. The answer
                // is degraded but readable, so it ships, and the note records it for tuning.
                flow.note("verify", "passed through with defect (\(check.reason))")
            }
            stageMark = Self.logStage("D · verify output language (+fallback)", since: stageMark)
        }

        guard !Task.isCancelled else { return }
        flow.output(finalResponse, language: Self.languageTag(detectedLanguage))
        continuation.yield(.final(finalResponse))
        _ = Self.logStage("TOTAL per-message", since: pipelineStart)
    }

    // MARK: - Stage timing

    /// Logs the elapsed time for a language-pipeline stage (⏱️, matching
    /// MedicalChatOrchestrator) and returns "now" so the caller can chain the next
    /// measurement. Monotonic clock, so wall-clock changes don't corrupt the numbers.
    @discardableResult
    private static func logStage(_ name: String, since mark: DispatchTime) -> DispatchTime {
        let now = DispatchTime.now()
        let elapsed = Double(now.uptimeNanoseconds &- mark.uptimeNanoseconds) / 1_000_000_000
        print(String(format: "⏱️ [ChatService] %@: %.3fs", name, elapsed))
        return now
    }

    // MARK: - Logging helpers

    /// Short language tag for the flow log ("en", "vi", "mixed", or the raw unsupported label).
    private static func languageTag(_ language: DetectedLanguage) -> String {
        switch language {
        case .vietnamese: return "vi"
        case .english:    return "en"
        case .mixed:      return "mixed"
        case .unsupported(let detected): return detected
        }
    }
}
