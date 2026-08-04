import Foundation

/// MedicalChatOrchestrator: full pipeline orchestration
/// English Query → Input GuardRail → RAG Retriever →
/// LLM Generation → Output GuardRail → Response
///
/// Everything up to generation runs in English: the query arrives translated, the guardrails
/// and the RAG corpus are English, and the retrieved context is injected in English. Only the
/// GENERATION step is language-aware — the model is told to answer in `responseLanguage`, so a
/// Vietnamese turn is written in Vietnamese in one pass instead of being generated in English
/// and then re-decoded by a second LLM translation pass (which cost more than the answer
/// itself). The output guardrail rules are bilingual to match; see GuardRailRules' output
/// section.
///
/// Emergency detection and input-language conversion live one layer up in ChatService,
/// which runs on the user's original-language text before this orchestrator is invoked.
final class MedicalChatOrchestrator {
    
    private let inputGuardRail: InputGuardRail
    private let outputGuardRail: OutputGuardRail
    private let ragService: RAGService
    private let llmService: LLMServiceProtocol
    private let factStore: SessionFactStore
    private let factExtractor: SessionFactExtractor

    init(
        llmService: LLMServiceProtocol,
        inputGuardRail: InputGuardRail = InputGuardRail(),
        outputGuardRail: OutputGuardRail = OutputGuardRail(),
        ragService: RAGService = RAGService(),
        factStore: SessionFactStore = AppConfig.sessionFactStore,
        factExtractor: SessionFactExtractor = SessionFactExtractor()
    ) {
        self.llmService = llmService
        self.inputGuardRail = inputGuardRail
        self.outputGuardRail = outputGuardRail
        self.ragService = ragService
        self.factStore = factStore
        self.factExtractor = factExtractor
    }

    /// Full orchestrated pipeline: query → guarded → retrieved → generated → guarded → stream
    /// - Parameter userQuery: The query in English. ChatService runs emergency detection on
    ///   the original-language text and translates it to English before calling this, so the
    ///   guardrails and RAG retrieval always operate on English.
    /// - Parameter images: images attached to this user turn. Text guardrails and RAG run on
    ///   the query text only; the images ride along into the LLM request (multimodal chat
    ///   convention) and are used when the loaded model supports vision.
    /// - Parameter responseLanguage: the language the LLM should ANSWER in — the user's
    ///   original language. Defaults to English. This is the only stage that differs by
    ///   language; the retrieved context stays English regardless and the model translates
    ///   the facts it uses as it writes.
    func processQuery(
        _ userQuery: String,
        images: [Data] = [],
        conversationHistory: [ChatMessage],
        conversationId: UUID,
        responseLanguage: DetectedLanguage = .english,
        onSourcesRetrieved: (@Sendable ([MedicalSource]) -> Void)? = nil
    ) -> AsyncStream<String> {
        return AsyncStream<String> { continuation in
            let task = Task {
                // Stage-timing: measure each pipeline stage so slow steps (long prefill,
                // extra LLM passes, buffered generation) show up in the console. Uses a
                // monotonic clock so it's unaffected by wall-clock adjustments.
                let pipelineStart = DispatchTime.now()
                var stageMark = pipelineStart

                // Step 1: Input GuardRail — dangerous/injection/PII checks, plus semantic
                // relevance. userQuery is always English by this point.
                let inputResult = inputGuardRail.validate(
                    query: userQuery,
                    englishQuery: userQuery
                )
                stageMark = Self.logStage("1 · InputGuardRail", since: stageMark)
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
                stageMark = Self.logStage("2 · RAG retrieval", since: stageMark)
                // Surface retrieved sources so the UI can show citations without a
                // second, redundant retrieval pass.
                onSourcesRetrieved?(retrievedContext.sources)

                // Step 3: Build enriched prompt with retrieved context, plus any facts the
                // user has stated earlier this session. Injecting the facts here (rather than
                // relying on the trimmed history) is what lets an early-mentioned detail — a
                // name, an allergy — survive after it scrolls out of the short history window.
                let rememberedFacts = await factStore.promptBlock(for: conversationId)
                let enrichedPrompt = buildEnrichedPrompt(
                    userQuery: sanitizedQuery,
                    context: retrievedContext,
                    history: conversationHistory,
                    rememberedFacts: rememberedFacts,
                    responseLanguage: responseLanguage
                )
                stageMark = Self.logStage("3 · Prompt build (+facts)", since: stageMark)

                // Step 4: Generate LLM response. This is buffered rather than streamed live
                // because outputGuardRail.validate (Step 5) inspects the COMPLETE response —
                // hallucination detection, unsafe dosage detection, and citation enforcement
                // all need the full text and can replace it outright. There is no safe way to
                // show tokens before that check runs.
                //
                // The LLM writes directly in `responseLanguage`, so a Vietnamese turn costs one
                // decode pass rather than two. ChatService still verifies the result actually
                // came out in the requested language and falls back to Apple Translation if the
                // model drifted — a deterministic check, not another LLM call.
                // Use the budget-trimmed history from EnrichedPrompt, not the raw conversationHistory,
                // so the total prompt length stays within the model's sweet spot.
                let (accumulatedResponse, generationStats) = await Self.accumulate(
                    stream: llmService.stream(request: LLMRequest(
                        systemPrompt: enrichedPrompt.systemPrompt,
                        userMessage: enrichedPrompt.userMessage,
                        conversationHistory: enrichedPrompt.history,
                        images: images
                    ))
                )
                stageMark = Self.logStage(
                    "4 · LLM generation", since: stageMark, detail: generationStats.summary
                )

                print("=== LLM Response ===\n\(accumulatedResponse)\n====================")

                // Step 5: Final Output GuardRail Check
                let outputResult = outputGuardRail.validate(
                    response: accumulatedResponse,
                    retrievedContext: retrievedContext,
                    responseLanguage: responseLanguage
                )
                stageMark = Self.logStage("5 · OutputGuardRail", since: stageMark)

                switch outputResult.status {
                case .blocked:
                    if let filtered = outputResult.filteredResponse {
                        continuation.yield(filtered)
                        continuation.yield(responseLanguage.requiresTranslation
                            ? "\n\n⚠️ [Nội dung đã được lọc vì lý do an toàn]"
                            : "\n\n⚠️ [Response filtered for safety]")
                    }
                case .allowed:
                    continuation.yield(accumulatedResponse)
                }

                // Step 6: Extract durable facts the user stated this turn and merge them into
                // the session store, so they're available to inject on later turns. Runs after
                // the response is delivered so it never delays the answer the user is waiting
                // on; a failed extraction just yields no new facts (fail-closed).
                if !Task.isCancelled {
                    let newFacts = await factExtractor.extract(from: sanitizedQuery, using: llmService)
                    await factStore.merge(newFacts, into: conversationId)
                    stageMark = Self.logStage("6 · Fact extraction (LLM)", since: stageMark)
                }

                _ = Self.logStage("TOTAL pipeline", since: pipelineStart)
                continuation.finish()
            }

            // Propagate consumer cancellation (e.g. user taps Stop) down to the LLM so
            // generation actually halts instead of running to completion in the background.
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    
    // MARK: - Private Helpers

    /// Timing captured while draining an LLM token stream. `ttft` isolates prefill cost
    /// (time-to-first-token) from decode; `chunkCount` approximates throughput. Because the
    /// orchestrator buffers the whole response before display, this is where the felt latency
    /// lives — the numbers here explain most of the app-vs-terminal gap.
    private struct GenerationStats {
        let ttft: TimeInterval
        let total: TimeInterval
        let chunkCount: Int

        /// e.g. "ttft 0.82s, 143 chunks, 18.4 chunk/s (decode)".
        var summary: String {
            let decode = max(total - ttft, 0)
            let rate = decode > 0 ? Double(max(chunkCount - 1, 0)) / decode : 0
            return String(
                format: "ttft %.2fs, %d chunks, %.1f chunk/s (decode)",
                ttft, chunkCount, rate
            )
        }
    }

    /// Drains an LLM token stream into a single string, recording time-to-first-token and
    /// chunk count alongside it.
    private static func accumulate(
        stream: AsyncStream<String>
    ) async -> (text: String, stats: GenerationStats) {
        let start = DispatchTime.now()
        var firstTokenAt: DispatchTime?
        var result = ""
        var chunkCount = 0
        for await token in stream {
            if firstTokenAt == nil { firstTokenAt = DispatchTime.now() }
            result += token
            chunkCount += 1
        }
        let end = DispatchTime.now()
        let ttft = seconds(from: start, to: firstTokenAt ?? end)
        let stats = GenerationStats(
            ttft: ttft,
            total: seconds(from: start, to: end),
            chunkCount: chunkCount
        )
        return (result, stats)
    }

    // MARK: - Stage Timing

    /// Logs the elapsed time for a pipeline stage and returns "now" so the caller can chain
    /// the next measurement. `detail` appends extra context (e.g. generation throughput).
    @discardableResult
    private static func logStage(
        _ name: String,
        since mark: DispatchTime,
        detail: String? = nil
    ) -> DispatchTime {
        let now = DispatchTime.now()
        let elapsed = seconds(from: mark, to: now)
        let suffix = detail.map { " — \($0)" } ?? ""
        print(String(format: "⏱️ [Orchestrator] %@: %.3fs%@", name, elapsed, suffix))
        return now
    }

    private static func seconds(from start: DispatchTime, to end: DispatchTime) -> TimeInterval {
        Double(end.uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000_000
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
        history: [ChatMessage],
        rememberedFacts: String? = nil,
        responseLanguage: DetectedLanguage = .english
    ) -> EnrichedPrompt {
        let answersInVietnamese = responseLanguage.requiresTranslation
        let languageInstruction = answersInVietnamese
            ? "Respond ONLY in Vietnamese (tiếng Việt). Do NOT use English, Chinese, or any other language under any circumstances."
            : "Respond ONLY in English. Do NOT use Chinese, Vietnamese, or any other language under any circumstances."

        // The RAG corpus is English, so the retrieved context below stays English even when the
        // answer must be Vietnamese. Say so explicitly — otherwise a small model tends to mirror
        // the language of the context it is quoting and drifts back into English mid-answer.
        let contextLanguageNote = answersInVietnamese ? """

        - The Retrieved Medical Context below is written in ENGLISH. Translate any fact you use
          from it into natural, everyday Vietnamese. Never quote it in English. Keep source
          titles and citation markers as they are, but write all of your own prose in Vietnamese.
        - Use plain Vietnamese a patient would use, not clinical loan-words, and keep medical
          terms accurate. Where a Vietnamese term is uncommon, put the English term in brackets
          after it once.
        """ : ""

        // Apply token budget to RAG chunks so the system prompt stays compact.
        let budgetedChunks = applyContextBudget(context.chunks, budget: Self.contextTokenBudget)

        // Facts the user has stated earlier this session (name, allergies, wound location, …).
        // Injected so they survive past the short history window; omitted entirely when empty.
        let memorySection = (rememberedFacts?.isEmpty == false) ? """

        Known facts about this patient (stated earlier in this conversation — use them, and do NOT ask for information already listed here):
        \(rememberedFacts!)
        """ : ""

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

        You are a warm, supportive medical informational assistant for colorectal cancer patients
        and their families — many of them elderly or recovering from surgery. Speak naturally and
        kindly, the way a caring nurse would. Your role is to provide educational health information.

        CONVERSATIONAL BEHAVIOR:
        - Patients talk to you like a person, not a search box. Respond naturally to greetings,
          thank-yous, and small talk ("hello", "thanks, that helps", "how are you").
        - When a user shares personal details ("I'm John", "I'm 26", "my surgery was last week"),
          acknowledge them warmly and remember them for the rest of the conversation. Never reject
          or ignore a message just because it isn't a clinical question.
        - Treat vague follow-ups ("is that normal?", "what about after a week?", "should I worry?")
          as continuations of the current health topic.

        IMPORTANT CONSTRAINTS:
        - \(languageInstruction)
        - You are NOT a licensed physician and cannot provide medical diagnosis or treatment plans.
        - Prefer the Retrieved Medical Context below when it is available — cite it and use it as the primary source.
        - The Retrieved Medical Context describes colorectal care in general; it is NOT this patient's
          record. Never state or imply that they have had a particular procedure, have a stoma, or are on
          a particular treatment unless they said so in this conversation or it is listed under known facts.
        - When the context is specific to a procedure or device the patient has not mentioned, keep that
          guidance conditional ("if you have had bowel surgery…", "if you have a stoma…") instead of
          asserting it as their situation. This applies to warning signs too — a red flag that only matters
          for one procedure must be framed for that procedure, not issued as a general alarm.
        - If the answer would differ materially depending on which procedure the patient had, ask one short
          clarifying question rather than guessing.
        - If the Retrieved Medical Context shows '[No relevant medical context found]', you may still answer common health and lifestyle questions (nutrition, diet, hydration, rest, activity) from your general medical knowledge, but clearly label the answer as general guidance and advise the user to confirm with their healthcare provider.
        - If — and only if — a question is genuinely unrelated to health, medicine, or the patient's care
          (e.g. coding help, math homework, general trivia), don't refuse coldly. Gently steer back:
          briefly note that you're here to support their health and recovery, then invite a health
          question — e.g. "I'm here to help with your health and recovery. Is there anything about your
          symptoms, treatment, or care I can help with?"
        - ALWAYS cite your sources when providing medical information.
        - Never recommend specific dosages confidently.
        - If the user describes emergency symptoms, immediately recommend calling emergency services.
        - For medical advice, include a disclaimer that they should consult with a healthcare provider.\(contextLanguageNote)\(noContextInstruction)\(memorySection)

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
