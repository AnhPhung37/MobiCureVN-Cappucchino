import Foundation

/// MedicalChatOrchestrator: full pipeline orchestration
/// User Query → Input GuardRail → Prompt Refiner → RAG Retriever → 
/// LLM Generation → Output GuardRail → Response
final class MedicalChatOrchestrator {
    
    private let inputGuardRail: InputGuardRail
    private let outputGuardRail: OutputGuardRail
    private let ragService: RAGService
    private let llmService: LLMServiceProtocol
    private let emergencyDetector: EmergencyDetector
    
    init(
        llmService: LLMServiceProtocol,
        inputGuardRail: InputGuardRail = InputGuardRail(),
        outputGuardRail: OutputGuardRail = OutputGuardRail(),
        ragService: RAGService = RAGService(),
        emergencyDetector: EmergencyDetector = EmergencyDetector()
    ) {
        self.llmService = llmService
        self.inputGuardRail = inputGuardRail
        self.outputGuardRail = outputGuardRail
        self.ragService = ragService
        self.emergencyDetector = emergencyDetector
    }
    
    /// Full orchestrated pipeline: query → guarded → retrieved → generated → guarded → stream
    /// - Parameter originalQuery: The pre-translation query (e.g. Vietnamese). When provided,
    ///   the input guardrail validates this instead of `userQuery` so that keyword matching
    ///   runs against the language the user actually typed.
    func processQuery(
        _ userQuery: String,
        conversationHistory: [ChatMessage],
        originalQuery: String? = nil
    ) -> AsyncStream<String> {
        return AsyncStream<String> { continuation in
            Task {
                do {
                    // Step 1: Input GuardRail — prefer the original (pre-translation) query
                    // so Vietnamese keyword matching works on the text the user typed.
                    let queryForGuardRail = originalQuery ?? userQuery
                    let inputResult = inputGuardRail.validate(query: queryForGuardRail)
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
                    
                    // Step 2: Emergency Detection (immediate redirect)
                    let emergency = emergencyDetector.detect(query: userQuery)
                    if emergency.isEmergency {
                        if let response = emergency.recommendation {
                            continuation.yield(response)
                        }
                        continuation.finish()
                        return
                    }
                    
                    // Step 3: RAG Pipeline (retrieve context)
                    let retrievedContext = await ragService.process(userQuery: sanitizedQuery)
                    
                    // Step 4: Build enriched prompt with retrieved context
                    let enrichedPrompt = buildEnrichedPrompt(
                        userQuery: sanitizedQuery,
                        context: retrievedContext,
                        history: conversationHistory
                    )
                    
                    // Step 5: Stream LLM response with output guardrail
                    var accumulatedResponse = ""
                    for await token in llmService.stream(request: LLMRequest(
                        systemPrompt: enrichedPrompt.systemPrompt,
                        userMessage: enrichedPrompt.userMessage,
                        conversationHistory: conversationHistory
                    )) {
                        accumulatedResponse += token
                        continuation.yield(token)
                    }
                    
                    // Step 6: Final Output GuardRail Check
                    let outputResult = outputGuardRail.validate(
                        response: accumulatedResponse,
                        retrievedContext: retrievedContext,
                        originalQuery: userQuery
                    )
                    
                    switch outputResult.status {
                    case .blocked(let reason):
                        // If output was blocked, stream the filtered version
                        if let filtered = outputResult.filteredResponse {
                            continuation.yield("\n\n⚠️ [Response filtered for safety]\n\(filtered)")
                        }
                    case .allowed:
                        // Already streamed, just finish
                        break
                    }
                    
                    continuation.finish()
                    
                } catch {
                    continuation.yield("Error: \(error.localizedDescription)")
                    continuation.finish()
                }
            }
        }
    }
    
    // MARK: - Private Helpers
    
    private struct EnrichedPrompt {
        let systemPrompt: String
        let userMessage: String
    }
    
    private func buildEnrichedPrompt(
        userQuery: String,
        context: RetrievedContext,
        history: [ChatMessage]
    ) -> EnrichedPrompt {
        let budgetedChunks = applyContextBudget(context.chunks, budget: 1500)
        let systemPrompt = """
        You are a medical informational assistant. Your role is to provide educational health information only.
        
        IMPORTANT CONSTRAINTS:
        - You are NOT a licensed physician and cannot provide medical diagnosis or treatment plans.
        - Always base your answers on the provided medical context below.
        - If you lack sufficient context, say: "I don't have reliable information to answer this safely."
        - ALWAYS cite your sources when providing medical information.
        - Never recommend specific dosages confidently.
        - If the user describes emergency symptoms, immediately recommend calling emergency services.
        - For medical advice, include a disclaimer that they should consult with a healthcare provider.
        
        Retrieved Medical Context:
        \(formatContextChunks(budgetedChunks))
        
        Sources:
        \(formatSources(context.sources))
        
        Confidence Score: \(String(format: "%.0f%%", context.confidenceScore * 100))
        """
        
        let userMessage = userQuery
        
        return EnrichedPrompt(systemPrompt: systemPrompt, userMessage: userMessage)
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
