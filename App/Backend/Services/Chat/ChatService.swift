import Foundation
import Combine

// MARK: - Processing State

// Describes which stage of the translation+generation pipeline is active.
// Drives the status indicator in ChatView.
enum ChatProcessingState: Equatable {
    case idle
    case validatingLanguage
    case translatingInput   // vi → en (for RAG retrieval only)
    case generating         // LLM is running
}

// MARK: - ChatService

// Top-level orchestrator: language validation → (optional translation) → LLM → stream.
// Wraps MedicalChatOrchestrator so the existing guardrail / RAG / LLM pipeline
// is unchanged; language handling is layered on top.
//
// For English input:  tokens stream live from the LLM in English.
// For Vietnamese / mixed input:
//   1. Translate input vi → en  (one-shot, shows .translatingInput) — used only for RAG retrieval
//   2. Pass original Vietnamese query to the LLM with a "respond in Vietnamese" instruction
//   3. Stream Vietnamese tokens directly from the LLM (no post-translation step)
@MainActor
final class ChatService: ObservableObject {

    @Published private(set) var processingState: ChatProcessingState = .idle

    private var orchestrator: MedicalChatOrchestrator
    private let languageValidator: LanguageValidationService
    private let translationService: TranslationService

    init(
        orchestrator: MedicalChatOrchestrator,
        languageValidator: LanguageValidationService = LanguageValidationService(),
        translationService: TranslationService
    ) {
        self.orchestrator = orchestrator
        self.languageValidator = languageValidator
        self.translationService = translationService
    }

    // Called when AppConfig swaps the underlying LLM service.
    func updateOrchestrator(_ newOrchestrator: MedicalChatOrchestrator) {
        orchestrator = newOrchestrator
    }

    // MARK: - Main Pipeline

    func processQuery(_ text: String, history: [ChatMessage]) -> AsyncStream<String> {
        // Language validation is synchronous — reject immediately if unsupported.
        processingState = .validatingLanguage
        let detected = languageValidator.detect(text)

        if case .unsupported = detected {
            processingState = .idle
            return AsyncStream { continuation in
                continuation.yield(LanguageValidationService.unsupportedErrorMessage)
                continuation.finish()
            }
        }

        let needsTranslation = detected.requiresTranslation

        return AsyncStream<String> { [weak self] continuation in
            guard let self else { continuation.finish(); return }

            let innerTask = Task { @MainActor [weak self] in
                guard let self else { continuation.finish(); return }

                do {
                    if needsTranslation {
                        try await self.runViToViPipeline(
                            originalText: text,
                            history: history,
                            continuation: continuation
                        )
                    } else {
                        try await self.runEnglishPipeline(
                            text: text,
                            history: history,
                            continuation: continuation
                        )
                    }
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

    // MARK: - Pipeline Branches

    // Vietnamese / mixed: translate vi→en for RAG only, then LLM responds in Vietnamese directly.
    private func runViToViPipeline(
        originalText: String,
        history: [ChatMessage],
        continuation: AsyncStream<String>.Continuation
    ) async throws {
        // Step 1: vi → en translation used only for RAG document retrieval.
        processingState = .translatingInput
        let englishQuery = try await translationService.translateToEnglish(originalText)

        guard !Task.isCancelled else { return }

        // Step 2: LLM receives the original Vietnamese query; system prompt instructs it
        // to respond in Vietnamese. The English translation is passed as ragQuery so the
        // retrieval layer can match English medical documents.
        processingState = .generating
        for await token in orchestrator.processQuery(
            originalText,
            conversationHistory: history,
            ragQuery: englishQuery,
            responseLanguage: .vietnamese
        ) {
            guard !Task.isCancelled else { return }
            continuation.yield(token)
        }
    }

    // English: stream LLM tokens directly.
    private func runEnglishPipeline(
        text: String,
        history: [ChatMessage],
        continuation: AsyncStream<String>.Continuation
    ) async throws {
        processingState = .generating
        for await token in orchestrator.processQuery(
            text,
            conversationHistory: history,
            responseLanguage: .english
        ) {
            guard !Task.isCancelled else { return }
            continuation.yield(token)
        }
    }
}
