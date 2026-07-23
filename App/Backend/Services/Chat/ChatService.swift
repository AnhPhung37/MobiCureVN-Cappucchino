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

    init(
        orchestrator: MedicalChatOrchestrator,
        languageValidator: LanguageValidationService = LanguageValidationService(),
        translationService: TranslationService,
        emergencyDetector: EmergencyDetector = EmergencyDetector()
    ) {
        self.orchestrator = orchestrator
        self.languageValidator = languageValidator
        self.translationService = translationService
        self.emergencyDetector = emergencyDetector
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

                // detect and refine both consume only the original text and are independent,
                // so run them concurrently to remove one LLM round-trip from the critical
                // path. Both are nonisolated LLM calls; the `async let` bindings start them
                // immediately and we await both below. The UI shows "validating language"
                // for the duration of this combined step (see processingState note below).
                let llmService = AppConfig.llmService
                async let detectedResult = self.languageValidator.detect(text, using: llmService)
                async let refinedResult = self.languageValidator.refine(text, using: llmService)

                let detected = await detectedResult

                if case .unsupported = detected {
                    // Discard the concurrently-running refine result; we're bailing out.
                    _ = await refinedResult
                    self.processingState = .idle
                    continuation.yield(LanguageValidationService.unsupportedErrorMessage)
                    continuation.finish()
                    return
                }

                let refinedText = await refinedResult

                do {
                    try await self.runPipeline(
                        refinedText: refinedText,
                        images: images,
                        detectedLanguage: detected,
                        history: history,
                        conversationId: conversationId,
                        onSourcesRetrieved: onSourcesRetrieved,
                        continuation: continuation
                    )
                } catch {
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
        history: [ChatMessage],
        conversationId: UUID,
        onSourcesRetrieved: (@Sendable ([MedicalSource]) -> Void)?,
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
                continuation.yield(response)
            }
            return
        }

        // Step 3: translate the refined input to English so the orchestrator only ever
        // has to work in one language.
        let englishQuery: String
        if detectedLanguage.requiresTranslation {
            processingState = .translatingInput
            englishQuery = try await translationService.translateToEnglish(refinedText)
        } else {
            englishQuery = refinedText
        }
        print("ChatService: englishQuery='\(englishQuery)'")

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

        guard !Task.isCancelled else { return }

        // Step 5: translate the English response back to the user's original language.
        // LLM-first: the model produces a noticeably more natural, conversational tone than
        // Apple Translation's fairly literal output.
        var finalResponse = englishResponse
        if detectedLanguage.requiresTranslation {
            processingState = .translatingOutput
            finalResponse = await languageValidator.translate(
                englishResponse,
                to: detectedLanguage,
                using: AppConfig.llmService
            )

            guard !Task.isCancelled else { return }

            // Step 6: verify the LLM translation. A small model can leak stray
            // foreign-script words or run out of generation budget on long responses — a
            // result much shorter than the source is treated as truncated. On failure, fall
            // back to Apple's Translation framework: literal in tone, but it doesn't leak.
            let looksComplete = finalResponse.count > englishResponse.count / 3
            let isValid = looksComplete
                ? await languageValidator.matches(
                    finalResponse,
                    expected: detectedLanguage,
                    using: AppConfig.llmService
                )
                : false
            if !isValid {
                // Best effort: if Apple Translation is also unavailable, ship the imperfect
                // LLM translation rather than erroring out the whole response.
                finalResponse = (try? await translationService.translateToVietnamese(englishResponse))
                    ?? finalResponse
            }
        }

        guard !Task.isCancelled else { return }
        continuation.yield(finalResponse)
    }
}
