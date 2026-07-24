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

// Top-level orchestrator: language validation → LLM refine → translate → LLM → translate back → stream.
// Wraps MedicalChatOrchestrator so the existing guardrail / RAG / LLM pipeline
// is unchanged; language handling is layered on top.
//
// The LLM (a small on-device model) never generates non-English *answers* — the medical
// pipeline only ever sees and produces English. On the way in, language conversion uses
// Apple's Translation framework; on the way out, the LLM translates the English response
// itself (noticeably more natural tone than Apple's literal output), verified by a
// validation pass with Apple Translation as the fallback when the LLM leaks or truncates:
//   1. Detect the input's language AND run the "refine" pass concurrently — both consume
//      only the original text and are independent, so they run via `async let` in parallel
//      to shave one LLM round-trip off a Vietnamese turn's latency.
//   2. LLM "refine" pass: fix typos and unify code-switching, staying in the same language.
//   3. Emergency detection on the refined original-language text.
//   4. Apple Translation: refined input → English (skipped if already English).
//   5. Orchestrator always generates English.
//   6. LLM translation: English response → original language (skipped if already English).
//   7. Validation pass: script scan + LLM check that the translation is complete and in the
//      original language; if not, fall back to Apple Translation of the English response.
//
// NOTE: MedicalChatOrchestrator buffers the full LLM output so the output guardrail can
// validate/redact it before delivery — the response arrives as one chunk, not token-by-token.
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
        onSourcesRetrieved: (@Sendable ([MedicalSource]) -> Void)? = nil
    ) -> AsyncStream<String> {
        processingState = .validatingLanguage

        return AsyncStream<String> { [weak self] continuation in
            guard let self else { continuation.finish(); return }

            let innerTask = Task { @MainActor [weak self] in
                guard let self else { continuation.finish(); return }

                let flow = ChatFlowLog()

                // Pin the user's name from the RAW input, before refine can mangle it (the
                // observed "I'm hanh" → "Haven't" corruption). The name is captured exactly as
                // typed and protected end-to-end so no LLM transform re-accents or rewrites it.
                let pinnedName = self.nameGuard.detectName(in: text)

                // detect and refine both consume only the original text and are independent,
                // so run them concurrently to remove one LLM round-trip from the critical
                // path. Both are nonisolated LLM calls; the `async let` bindings start them
                // immediately and we await both below. The UI shows "validating language"
                // for the duration of this combined step (see processingState note below).
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
                if case .unsupported = detected, !images.isEmpty {
                    effectiveDetected = self.languageValidator.vietnameseDensity(text) > 0
                        ? .vietnamese
                        : .english
                } else if case .unsupported = detected {
                    // Text-only turn in a genuinely unsupported language: refuse as before.
                    // Discard the concurrently-running refine result; we're bailing out.
                    _ = await refinedResult
                    flow.end("unsupported language")
                    self.processingState = .idle
                    continuation.yield(LanguageValidationService.unsupportedErrorMessage)
                    continuation.finish()
                    return
                } else {
                    effectiveDetected = detected
                }

                // Restore the pinned name into the refined text, undoing the protective
                // sentinel so downstream stages see natural text with the correct spelling.
                let refinedText = self.nameGuard.restore(await refinedResult, name: pinnedName)
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
                        flow: flow,
                        continuation: continuation
                    )
                } catch {
                    flow.end("error: \(error.localizedDescription)")
                    let msg = "Lỗi xử lý: \(error.localizedDescription)\n" +
                              "Processing error: \(error.localizedDescription)"
                    continuation.yield(msg)
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
        flow: ChatFlowLog,
        continuation: AsyncStream<String>.Continuation
    ) async throws {
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
                continuation.yield(response)
            } else {
                flow.end("emergency (no template)")
            }
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
            flow.stage("translate→en", englishQuery, tag: "en")
        } else {
            englishQuery = refinedText
        }

        guard !Task.isCancelled else { return }

        // Step 4: orchestrator always generates English. The buffered response is
        // delivered as a single item at the end (see class-level NOTE).
        processingState = .generating
        var englishResponse = ""
        for await token in orchestrator.processQuery(
            englishQuery,
            images: images,
            conversationHistory: history,
            conversationId: conversationId,
            onSourcesRetrieved: onSourcesRetrieved
        ) {
            guard !Task.isCancelled else { return }
            englishResponse += token
        }
        flow.stage("generate→en", englishResponse, tag: "en")

        guard !Task.isCancelled else { return }

        // Step 5: translate the English response back to the user's original language.
        // LLM-first: the model produces a noticeably more natural, conversational tone than
        // Apple Translation's fairly literal output. The name is protected across the LLM
        // translation so it can't be re-accented (the observed "Hanh" → "Hạnh").
        var finalResponse = englishResponse
        if detectedLanguage.requiresTranslation {
            processingState = .translatingOutput
            let protectedResponse = nameGuard.protect(englishResponse, name: pinnedName)
            let translatedOut = await languageValidator.translate(
                protectedResponse,
                to: detectedLanguage,
                using: AppConfig.llmService
            )
            finalResponse = nameGuard.restore(translatedOut, name: pinnedName)
            flow.stage("translate→vi", finalResponse, tag: "vi")

            guard !Task.isCancelled else { return }

            // Step 6: verify the LLM translation. A small model can (a) leak stray
            // foreign-script words, (b) leave an English run untranslated — the "Tôi sorry…"
            // code-switch — or (c) run out of generation budget on long responses, where a
            // result much shorter than the source is treated as truncated. Any of these fails
            // verification and falls back to Apple's Translation framework: literal in tone,
            // but it neither leaks nor code-switches.
            let looksComplete = finalResponse.count > englishResponse.count / 3
            let hasEnglishLeak = languageValidator.containsEnglishLeak(finalResponse)
            let isValid = looksComplete && !hasEnglishLeak
                ? await languageValidator.matches(
                    finalResponse,
                    expected: detectedLanguage,
                    using: AppConfig.llmService
                )
                : false
            if !isValid {
                let reason = hasEnglishLeak ? "code-switch leak"
                    : (looksComplete ? "language mismatch" : "truncated")
                flow.note("verify", "fallback → Apple Translation (\(reason))")
                // Best effort: if Apple Translation is also unavailable, ship the imperfect
                // LLM translation rather than erroring out the whole response. The name is
                // protected here too so the fallback path can't re-accent it either.
                if let appleOut = try? await translationService.translateToVietnamese(
                    nameGuard.protect(englishResponse, name: pinnedName)
                ) {
                    finalResponse = nameGuard.restore(appleOut, name: pinnedName)
                }
            } else {
                flow.note("verify", "ok (llm)")
            }
        }

        guard !Task.isCancelled else { return }
        flow.output(finalResponse, language: Self.languageTag(detectedLanguage))
        continuation.yield(finalResponse)
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
