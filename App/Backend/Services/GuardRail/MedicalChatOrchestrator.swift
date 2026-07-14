import Foundation

/// MedicalChatOrchestrator: full pipeline orchestration (English-only)
/// English Query → Input GuardRail → RAG Retriever →
/// LLM Generation → Output GuardRail → Response
///
/// Emergency detection and language conversion live one layer up in ChatService,
/// which runs on the user's original-language text before this orchestrator is invoked.
final class MedicalChatOrchestrator {
    
    private let inputGuardRail: InputGuardRail
    private let outputGuardRail: OutputGuardRail
    private let ragService: RAGService
    private let llmService: LLMServiceProtocol

    init(
        llmService: LLMServiceProtocol,
        inputGuardRail: InputGuardRail = InputGuardRail(),
        outputGuardRail: OutputGuardRail = OutputGuardRail(),
        ragService: RAGService = RAGService()
    ) {
        self.llmService = llmService
        self.inputGuardRail = inputGuardRail
        self.outputGuardRail = outputGuardRail
        self.ragService = ragService
    }

    /// Full orchestrated pipeline: query → guarded → retrieved → generated → guarded → stream
    /// - Parameter userQuery: The query in English. ChatService runs emergency detection on
    ///   the original-language text and translates it to English before calling this, then
    ///   translates the (always-English) response back afterward — this orchestrator only
    ///   ever sees/generates English.
    func processQuery(
        _ userQuery: String,
        conversationHistory: [ChatMessage],
        onSourcesRetrieved: (@Sendable ([MedicalSource]) -> Void)? = nil
    ) -> AsyncStream<String> {
        return AsyncStream<String> { continuation in
            let task = Task {
                // Step 1: Input GuardRail — dangerous/injection/PII checks, plus semantic
                // relevance. userQuery is always English by this point.
                let inputResult = inputGuardRail.validate(
                    query: userQuery,
                    englishQuery: userQuery
                )
                switch inputResult.status {
                case .blocked(let reason):
                    continuation.yield("❌ \(reason)\n\n")
                    if let violation = inputResult.violations.first {
                        continuation.yield("Reason: \(violation)")
                    }
                    continuation.finish()
                    return
                case .allowed:
                    break
                }

                let sanitizedQuery = inputResult.sanitizedQuery ?? userQuery

                // Step 2: RAG Pipeline — sanitizedQuery is always English by this point.
                let retrievedContext = await ragService.process(userQuery: sanitizedQuery)
                // Surface retrieved sources so the UI can show citations without a
                // second, redundant retrieval pass.
                onSourcesRetrieved?(retrievedContext.sources)

                // Step 3: Build enriched prompt with retrieved context
                let enrichedPrompt = buildEnrichedPrompt(
                    userQuery: sanitizedQuery,
                    context: retrievedContext,
                    history: conversationHistory
                )

                // Step 4: Generate LLM response. This is buffered rather than streamed live
                // because outputGuardRail.validate (Step 5) inspects the COMPLETE response —
                // hallucination detection, unsafe dosage detection, and citation enforcement
                // all need the full text and can replace it outright. There is no safe way to
                // show tokens before that check runs.
                //
                // The LLM only ever generates English here — ChatService handles translating
                // the user's original-language input to English beforehand and the English
                // response back afterward, so there's no language-matching/retry step needed
                // at this layer.
                // Use the budget-trimmed history from EnrichedPrompt, not the raw conversationHistory,
                // so the total prompt length stays within the model's sweet spot.
                let accumulatedResponse = await Self.accumulate(
                    stream: llmService.stream(request: LLMRequest(
                        systemPrompt: enrichedPrompt.systemPrompt,
                        userMessage: enrichedPrompt.userMessage,
                        conversationHistory: enrichedPrompt.history
                    ))
                )

                print("=== LLM Response ===\n\(accumulatedResponse)\n====================")

                // Step 5: Final Output GuardRail Check
                let outputResult = outputGuardRail.validate(
                    response: accumulatedResponse,
                    retrievedContext: retrievedContext,
                    originalQuery: userQuery
                )

                switch outputResult.status {
                case .blocked:
                    if let filtered = outputResult.filteredResponse {
                        continuation.yield(filtered)
                        continuation.yield("\n\n⚠️ [Response filtered for safety]")
                    }
                case .allowed:
                    continuation.yield(accumulatedResponse)
                }

                continuation.finish()
            }

            // Propagate consumer cancellation (e.g. user taps Stop) down to the LLM so
            // generation actually halts instead of running to completion in the background.
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    
    // MARK: - Private Helpers

    /// Drains an LLM token stream into a single string.
    private static func accumulate(stream: AsyncStream<String>) async -> String {
        var result = ""
        for await token in stream {
            result += token
        }
        return result
    }

    private struct EnrichedPrompt {
        let systemPrompt: String
        let userMessage: String
        /// History trimmed to `maxHistoryTurns` so the LLM prompt stays compact.
        let history: [ChatMessage]
    }
    
    // Token budget for RAG context injected into the system prompt.
    // Keeps the total prompt size reasonable for a 3B model, bounding prefill time.
    private static let contextTokenBudget = 600
    // Maximum number of past turns included in the conversation history sent to the LLM.
    // Each turn = 1 user + 1 assistant message. Older turns are dropped to limit prompt length.
    private static let maxHistoryTurns = 4

    private func buildEnrichedPrompt(
        userQuery: String,
        context: RetrievedContext,
        history: [ChatMessage]
    ) -> EnrichedPrompt {
        let languageInstruction = "Respond ONLY in English. Do NOT use Chinese, Vietnamese, or any other language under any circumstances."

        // Apply token budget to RAG chunks so the system prompt stays compact.
        let budgetedChunks = applyContextBudget(context.chunks, budget: Self.contextTokenBudget)

        let noContextFound = budgetedChunks.isEmpty
        let noContextInstruction = noContextFound ? """

        ⚠️ KNOWLEDGE BASE NOTE:
        No specific documents were retrieved for this query. However, if the question is a common health or
        lifestyle concern (e.g. what to eat, what to avoid, daily habits, nutrition, hydration, rest) that
        patients typically ask in a medical context, you MAY answer using your general medical knowledge.
        - Always frame the answer as general health guidance, not personalised medical advice.
        - Include a disclaimer recommending the patient consult their healthcare provider for advice tailored to their condition.
        - Do NOT answer questions that are clearly unrelated to health or medicine.
        """ : ""

        let systemPrompt = """
        LANGUAGE: \(languageInstruction)

        You are a medical informational assistant. Your role is to provide educational health information only.

        IMPORTANT CONSTRAINTS:
        - \(languageInstruction)
        - You are NOT a licensed physician and cannot provide medical diagnosis or treatment plans.
        - Prefer the Retrieved Medical Context below when it is available — cite it and use it as the primary source.
        - If the Retrieved Medical Context shows '[No relevant medical context found]', you may still answer common health and lifestyle questions (nutrition, diet, hydration, rest, activity) from your general medical knowledge, but clearly label the answer as general guidance and advise the user to confirm with their healthcare provider.
        - If the question is clearly unrelated to health or medicine, politely decline and explain you can only assist with health topics.
        - ALWAYS cite your sources when providing medical information.
        - Never recommend specific dosages confidently.
        - If the user describes emergency symptoms, immediately recommend calling emergency services.
        - For medical advice, include a disclaimer that they should consult with a healthcare provider.\(noContextInstruction)

        Retrieved Medical Context:
        \(formatContextChunks(budgetedChunks))

        Sources:
        \(formatSources(context.sources))

        Confidence Score: \(String(format: "%.0f%%", context.confidenceScore * 100))

        REMINDER — \(languageInstruction)
        """

        // Cap history to the most recent N turns so the prompt stays short.
        // Older context is less useful for a 3B model and significantly increases prefill time.
        let maxMessages = Self.maxHistoryTurns * 2
        let trimmedHistory = history.count > maxMessages
            ? Array(history.suffix(maxMessages))
            : history

        return EnrichedPrompt(systemPrompt: systemPrompt, userMessage: userQuery, history: trimmedHistory)
    }

    private func applyContextBudget(_ chunks: [ContextChunk], budget: Int) -> [ContextChunk] {
        var usedTokens = 0
        var selected: [ContextChunk] = []

        for chunk in chunks {
            let estimate = chunk.content.split { $0.isWhitespace }.count
            if usedTokens + estimate > budget { break }
            usedTokens += estimate
            selected.append(chunk)
        }

        return selected
    }
    
    private func formatContextChunks(_ chunks: [ContextChunk]) -> String {
        guard !chunks.isEmpty else {
            return "[No relevant medical context found]"
        }
        
        return chunks.enumerated().map { index, chunk in
            let sectionLabel = chunk.section.isEmpty ? "General" : chunk.section
            return """
            ---
            Context \(index + 1) (\(sectionLabel)):
            \(chunk.content)
            """
        }.joined(separator: "\n")
    }
    
    private func formatSources(_ sources: [MedicalSource]) -> String {
        guard !sources.isEmpty else {
            return "[No sources available]"
        }
        
        return sources.enumerated().map { index, source in
            let pageStr = source.page > 0 ? " (p.\(source.page))" : ""
            return "[\(index + 1)] \(source.title) - \(source.documentName)\(pageStr)"
        }.joined(separator: "\n")
    }
}
