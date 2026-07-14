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
    case translatingOutput  // en → original language (Apple Translation)
}

// MARK: - ChatService

// Top-level orchestrator: language validation → LLM refine → translate → LLM → translate back → stream.
// Wraps MedicalChatOrchestrator so the existing guardrail / RAG / LLM pipeline
// is unchanged; language handling is layered on top.
//
// The LLM (a small on-device model) never generates non-English prose — it only ever sees
// and produces English, plus small classification/refine/translate-fallback prompts. All
// actual language conversion is done by Apple's Translation framework, which is far less
// prone to leaking stray foreign words than asking a 3B model to write Vietnamese directly:
//   1. Detect the input's language.
//   2. LLM "refine" pass: fix typos and unify code-switching, staying in the same language.
//   3. Emergency detection on the refined original-language text.
//   4. Apple Translation: refined input → English (skipped if already English).
//   5. Orchestrator always generates English.
//   6. Apple Translation: English response → original language (skipped if already English).
//   7. LLM validation pass: confirm the translated response is actually in the original
//      language; if not, fall back to an LLM-driven translation of the English response.
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

    func processQuery(
        _ text: String,
        history: [ChatMessage],
        onSourcesRetrieved: (@Sendable ([MedicalSource]) -> Void)? = nil
    ) -> AsyncStream<String> {
        processingState = .validatingLanguage

        return AsyncStream<String> { [weak self] continuation in
            guard let self else { continuation.finish(); return }

            let innerTask = Task { @MainActor [weak self] in
                guard let self else { continuation.finish(); return }

                let detected = await self.languageValidator.detect(text, using: AppConfig.llmService)

                if case .unsupported = detected {
                    self.processingState = .idle
                    continuation.yield(LanguageValidationService.unsupportedErrorMessage)
                    continuation.finish()
                    return
                }

                do {
                    try await self.runPipeline(
                        originalText: text,
                        detectedLanguage: detected,
                        history: history,
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
        originalText: String,
        detectedLanguage: DetectedLanguage,
        history: [ChatMessage],
        onSourcesRetrieved: (@Sendable ([MedicalSource]) -> Void)?,
        continuation: AsyncStream<String>.Continuation
    ) async throws {
        // Step 1: LLM refine pass — fix typos and unify code-switching, same language.
        processingState = .refiningInput
        let refinedText = await languageValidator.refine(originalText, using: AppConfig.llmService)

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

        guard !Task.isCancelled else { return }

        // Step 4: orchestrator always generates English. The buffered response is
        // delivered as a single item at the end (see class-level NOTE).
        processingState = .generating
        var englishResponse = ""
        for await token in orchestrator.processQuery(
            englishQuery,
            conversationHistory: history,
            onSourcesRetrieved: onSourcesRetrieved
        ) {
            guard !Task.isCancelled else { return }
            englishResponse += token
        }

        guard !Task.isCancelled else { return }

        // Step 5: translate the English response back to the user's original language.
        var finalResponse = englishResponse
        if detectedLanguage.requiresTranslation {
            processingState = .translatingOutput
            finalResponse = try await translationService.translateToVietnamese(englishResponse)

            guard !Task.isCancelled else { return }

            // Step 6: LLM validation — confirm the translated text is actually Vietnamese.
            // Apple Translation can occasionally echo the source back unchanged or drop a
            // word; if validation fails, fall back to an LLM-driven translation instead of
            // shipping a wrong-language response.
            let isValid = await languageValidator.matches(
                finalResponse,
                expected: detectedLanguage,
                using: AppConfig.llmService
            )
            if !isValid {
                finalResponse = await languageValidator.translateAsFallback(
                    englishResponse,
                    to: detectedLanguage,
                    using: AppConfig.llmService
                )
            }
        }

        guard !Task.isCancelled else { return }
        continuation.yield(finalResponse)
    }
}
