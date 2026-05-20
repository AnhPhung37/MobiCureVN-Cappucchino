import Foundation
import Combine

// MARK: - Processing State

// Describes which stage of the translation+generation pipeline is active.
// Drives the status indicator in ChatView.
enum ChatProcessingState: Equatable {
    
    case idle
    case validatingLanguage
    case translatingInput       // vi → en before the LLM
    case generating             // LLM is running
    case translatingOutput      // en → vi after the LLM
}

// MARK: - ChatService

// Top-level orchestrator: language validation → translation → LLM → translation.
// Wraps MedicalChatOrchestrator so the existing guardrail / RAG / LLM pipeline
// is unchanged; translation is layered on top.
//
// For English input:  tokens stream live from the LLM (no translation overhead).
// For Vietnamese / mixed input:
//   1. Translate input vi → en  (one-shot, shows .translatingInput)
//   2. Accumulate full LLM response in English
//   3. Translate response en → vi  (one-shot, shows .translatingOutput)
//   4. Yield the Vietnamese words one-by-one to preserve the streaming feel
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

    // Vietnamese / mixed: translate → LLM → translate back
    private func runViToViPipeline(
        originalText: String,
        history: [ChatMessage],
        continuation: AsyncStream<String>.Continuation
    ) async throws {
        // Step 1: vi → en
        processingState = .translatingInput
        let englishQuery = try await translationService.translateToEnglish(originalText)

        guard !Task.isCancelled else { return }

        // Step 2: LLM (accumulate; cannot stream because we must translate the whole response)
        // Pass originalText so the guardrail validates the pre-translation query (Vietnamese
        // keywords match the text the user typed, not the English translation).
        processingState = .generating
        var fullEnglishResponse = ""
        for await token in orchestrator.processQuery(englishQuery, conversationHistory: history, originalQuery: originalText) {
            guard !Task.isCancelled else { return }
            fullEnglishResponse += token
        }

        guard !Task.isCancelled, !fullEnglishResponse.isEmpty else { return }

        // Step 3: en → vi
        processingState = .translatingOutput
        let vietnameseResponse = try await translationService.translateToVietnamese(fullEnglishResponse)

        guard !Task.isCancelled else { return }

        // Step 4: Fake-stream the Vietnamese result word-by-word to preserve UX feel.
        processingState = .idle
        let tokens = vietnameseResponse.split(separator: " ", omittingEmptySubsequences: false)
        for (index, word) in tokens.enumerated() {
            guard !Task.isCancelled else { return }
            let chunk = index == 0 ? String(word) : " \(word)"
            continuation.yield(chunk)
        }
    }

    // English: stream LLM tokens directly with no translation overhead.
    private func runEnglishPipeline(
        text: String,
        history: [ChatMessage],
        continuation: AsyncStream<String>.Continuation
    ) async throws {
        processingState = .generating
        for await token in orchestrator.processQuery(text, conversationHistory: history) {
            guard !Task.isCancelled else { return }
            continuation.yield(token)
        }
    }
}
