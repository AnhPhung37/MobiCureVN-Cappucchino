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
    private let profileRepository: ProfileRepository
    private let profileUpdateExtractor: ProfileUpdateExtractor
    private let profileUpdateStore: ProfileUpdateRepository

    init(
        llmService: LLMServiceProtocol,
        inputGuardRail: InputGuardRail = InputGuardRail(),
        outputGuardRail: OutputGuardRail = OutputGuardRail(),
        ragService: RAGService = RAGService(),
        factStore: SessionFactStore = AppConfig.sessionFactStore,
        factExtractor: SessionFactExtractor = SessionFactExtractor(),
        profileRepository: ProfileRepository = AppConfig.profileRepository,
        profileUpdateExtractor: ProfileUpdateExtractor = ProfileUpdateExtractor(),
        profileUpdateStore: ProfileUpdateRepository = AppConfig.profileUpdateStore
    ) {
        self.llmService = llmService
        self.inputGuardRail = inputGuardRail
        self.outputGuardRail = outputGuardRail
        self.ragService = ragService
        self.factStore = factStore
        self.factExtractor = factExtractor
        self.profileRepository = profileRepository
        self.profileUpdateExtractor = profileUpdateExtractor
        self.profileUpdateStore = profileUpdateStore
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
        onSourcesRetrieved: (@Sendable ([MedicalSource]) -> Void)? = nil,
        onProfileUpdateProposed: (@Sendable ([ProposedProfileUpdate]) -> Void)? = nil,
        responseLanguage: DetectedLanguage = .english
    ) -> AsyncStream<ChatStreamEvent> {
        // Only the newest event is worth keeping: previews are cumulative snapshots, so a
        // consumer that falls behind should skip to the current one rather than replay every
        // intermediate frame it missed. The `.final` is safe from the policy — it is yielded
        // last, and this buffer only ever discards elements older than the newest.
        return AsyncStream<ChatStreamEvent>(bufferingPolicy: .bufferingNewest(1)) { continuation in
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
                    // One `.final` per turn, so the refusal and its reason ship together
                    // rather than as two events that would overwrite each other.
                    var refusal = "❌ \(reason)\n\n"
                    if let violation = inputResult.violations.first {
                        refusal += "Reason: \(violation)"
                    }
                    continuation.yield(.final(refusal))
                    continuation.finish()
                    return
                case .allowed:
                    break
                }

                let sanitizedQuery = inputResult.sanitizedQuery ?? userQuery

                // The confirmed, cross-conversation profile. Fetched before retrieval (not just
                // before prompt building) because Step 2 uses the patient's diagnosis and
                // procedure to bias what comes back — a question asked by someone with an
                // ileostomy should surface ileostomy chunks. A best-effort read: a fetch failure
                // just means this turn runs without personalization rather than failing outright.
                let confirmedProfile = try? await profileRepository.fetchProfile()

                // Step 2: RAG Pipeline — sanitizedQuery is always English by this point.
                let retrievedContext = await ragService.process(
                    userQuery: sanitizedQuery,
                    profileTerms: confirmedProfile.map(Self.retrievalTerms) ?? []
                )
                stageMark = Self.logStage("2 · RAG retrieval", since: stageMark)
                // Narrow retrieval to what the context budget lets the model read BEFORE anything
                // describes it. The prompt's Sources list, the citation cards and the output
                // guardrail all receive this packed context, so none of them can name a document
                // whose passage was packed out — a citation the answer cannot be based on.
                let packedContext = Self.packed(
                    retrievedContext,
                    budget: Self.contextTokenBudget,
                    ratio: Self.wordsToTokensRatio
                )
                // Surface the sources so the UI can show citations without a second,
                // redundant retrieval pass.
                onSourcesRetrieved?(packedContext.sources)

                // Step 3: Build enriched prompt with retrieved context, plus any facts the
                // user has stated earlier this session. Injecting the facts here (rather than
                // relying on the trimmed history) is what lets an early-mentioned detail — a
                // name, an allergy — survive after it scrolls out of the short history window.
                let rememberedFacts = await factStore.promptBlock(for: conversationId)
                let enrichedPrompt = buildEnrichedPrompt(
                    userQuery: sanitizedQuery,
                    context: packedContext,
                    history: conversationHistory,
                    rememberedFacts: rememberedFacts,
                    confirmedProfile: confirmedProfile,
                    responseLanguage: responseLanguage
                )
                stageMark = Self.logStage("3 · Prompt build (+facts)", since: stageMark)

                // Step 4: Generate LLM response. The ANSWER is still buffered rather than
                // streamed, because outputGuardRail.validate (Step 5) inspects the COMPLETE
                // response — hallucination detection, unsafe dosage detection, and citation
                // enforcement all need the full text and can replace it outright. Tokens are
                // additionally emitted as `.preview` events purely so the UI can show the reply
                // being written; they are explicitly unvalidated and get replaced by the
                // `.final` event below (see ChatStreamEvent).
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
                    )),
                    previewingTo: continuation
                )
                stageMark = Self.logStage(
                    "4 · LLM generation", since: stageMark, detail: generationStats.summary
                )

                // The complete answer is patient-facing medical text derived from the user's own
                // message; it must not be written to the device log in a release build. Even in
                // DEBUG, ChatFlowLog's elided one-line sample is usually the better tool.
                #if DEBUG
                print("=== LLM Response ===\n\(accumulatedResponse)\n====================")
                #endif

                // Step 5: Final Output GuardRail Check
                let outputResult = outputGuardRail.validate(
                    response: accumulatedResponse,
                    retrievedContext: packedContext,
                    responseLanguage: responseLanguage
                )
                stageMark = Self.logStage("5 · OutputGuardRail", since: stageMark)

                switch outputResult.status {
                case .blocked:
                    if let filtered = outputResult.filteredResponse {
                        let notice = responseLanguage.requiresTranslation
                            ? "\n\n⚠️ [Nội dung đã được lọc vì lý do an toàn]"
                            : "\n\n⚠️ [Response filtered for safety]"
                        continuation.yield(.final(filtered + notice))
                    }
                case .allowed:
                    continuation.yield(.final(accumulatedResponse))
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

                // Step 7: propose durable, cross-conversation profile updates from this turn,
                // diffed against the confirmed profile already fetched in Step 3. This never
                // writes the profile directly — proposals are staged for explicit patient
                // confirmation (see ProfileUpdateRepository). Runs after the answer is
                // delivered, same rationale as Step 6.
                if !Task.isCancelled, let currentProfile = confirmedProfile {
                    let proposals = await profileUpdateExtractor.extract(
                        from: sanitizedQuery, currentProfile: currentProfile, using: llmService
                    )
                    var enqueuedCount = 0
                    if !proposals.isEmpty {
                        let candidates = proposals.map {
                            ProposedProfileUpdate(
                                proposal: $0,
                                currentProfile: currentProfile,
                                conversationId: conversationId,
                                sourceExcerpt: String(sanitizedQuery.prefix(200))
                            )
                        }
                        if let enqueued = try? await profileUpdateStore.enqueue(candidates), !enqueued.isEmpty {
                            enqueuedCount = enqueued.count
                            onProfileUpdateProposed?(enqueued)
                        }
                    }
                    // This step is a second LLM pass that fails closed at three separate points
                    // (nothing proposed / unparseable reply / enqueue deduped), all of which look
                    // identical from the UI: no card. Report which one happened.
                    _ = Self.logStage(
                        "7 · Profile update proposals", since: stageMark,
                        detail: "\(proposals.count) proposed, \(enqueuedCount) staged"
                    )
                } else if !Task.isCancelled {
                    _ = Self.logStage(
                        "7 · Profile update proposals", since: stageMark,
                        detail: "skipped — profile fetch failed"
                    )
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

    /// How often the draft-so-far is pushed to the UI while decoding. The model emits chunks
    /// faster than anyone can read them, and each snapshot costs a hop to the main actor plus a
    /// re-layout of the whole message list, so they are coalesced: ~20 updates a second still
    /// looks continuous while keeping the cost independent of decode speed.
    private static let previewInterval: TimeInterval = 0.05

    /// Drains an LLM token stream into a single string, recording time-to-first-token and
    /// chunk count alongside it, and emitting the text-so-far as `.preview` events on the way.
    ///
    /// The previews are the raw decoder output — no guardrail has run yet. They are display
    /// only; the caller replaces them with a `.final` once Step 5 has validated the whole thing.
    private static func accumulate(
        stream: AsyncStream<String>,
        previewingTo continuation: AsyncStream<ChatStreamEvent>.Continuation
    ) async -> (text: String, stats: GenerationStats) {
        let start = DispatchTime.now()
        var firstTokenAt: DispatchTime?
        var lastPreviewAt = start
        var result = ""
        var chunkCount = 0
        for await token in stream {
            if firstTokenAt == nil { firstTokenAt = DispatchTime.now() }
            result += token
            chunkCount += 1

            let now = DispatchTime.now()
            if seconds(from: lastPreviewAt, to: now) >= previewInterval {
                lastPreviewAt = now
                continuation.yield(.preview(result))
            }
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
    ///
    /// DEBUG-only output, matching the rule `ChatFlowLog` already applies to itself: a release
    /// build should not pay for `String(format:)` plus a console write on every stage of every
    /// turn. The mark is still returned in release, so call-site chaining is identical.
    @discardableResult
    private static func logStage(
        _ name: String,
        since mark: DispatchTime,
        detail: String? = nil
    ) -> DispatchTime {
        let now = DispatchTime.now()
        #if DEBUG
        let elapsed = seconds(from: mark, to: now)
        let suffix = detail.map { " — \($0)" } ?? ""
        print(String(format: "⏱️ [Orchestrator] %@: %.3fs%@", name, elapsed, suffix))
        #endif
        return now
    }

    private static func seconds(from start: DispatchTime, to end: DispatchTime) -> TimeInterval {
        Double(end.uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000_000
    }

    private struct EnrichedPrompt {
        let systemPrompt: String
        let userMessage: String
        /// History trimmed to `historyTokenBudget`, with assistant turns condensed.
        let history: [ChatMessage]
    }

    /// Prompt budgets come from `InferenceTuning`, which loads them from a JSON file at launch
    /// rather than compiling them in — so a sweep over context/history size is a file edit and
    /// a relaunch, not a rebuild. See `Docs/BE/inferenceTuning.md`.
    private static var tuning: InferenceTuning.Prompt { InferenceTuning.current.prompt }

    // Token budget for RAG context injected into the system prompt, bounding prefill time.
    //
    // Read from `InferenceTuning` like every other prompt budget. It used to be a hardcoded
    // 600 here while `InferenceTuning.Prompt.contextTokenBudget` existed and was parsed from
    // the JSON — so editing the JSON silently did nothing, and the value was never actually
    // tunable. See Docs/BE/Context-Budget-Finding.md.
    private static var contextTokenBudget: Int { tuning.contextTokenBudget }
    // Token budget for the persisted patient profile block. Smaller than the RAG budget —
    // these are compact structured facts, not prose.
    private static let profileTokenBudget = 200
    // Word cap on the report summary before it enters the profile block. The only free-text
    // field in the profile, and the one least useful turn to turn; capping it keeps the
    // structured fields (diagnosis, procedure, allergies) inside the budget above.
    private static let reportSummaryWordCap = 40
    // Maximum number of past turns included in the conversation history sent to the LLM.
    // Each turn = 1 user + 1 assistant message. Older turns are dropped to limit prompt length.
    private static let maxHistoryTurns = 4
    // Token budget for the replayed conversation history, mirroring `contextTokenBudget`.
    // A turn count is the wrong unit here: four turns of one-line greetings and four turns of
    // full medical answers differ by an order of magnitude in prefill cost, and it is the
    // tokens — not the turns — that the model has to re-read on every message. Budgeting by
    // tokens bounds history growth directly, whatever shape the conversation takes.
    private static var historyTokenBudget: Int { tuning.historyTokenBudget }
    // Word cap applied to an assistant turn before it is replayed to the model. The full text
    // stays in the UI and in storage; only the copy fed back into the prompt is shortened.
    // Continuity needs the gist of what was already said, not the markdown headings, bullet
    // lists, and disclaimers that make up most of a long answer's length.
    private static var assistantReplayWordCap: Int { tuning.assistantReplayWordCap }

    private func buildEnrichedPrompt(
        userQuery: String,
        context: RetrievedContext,
        history: [ChatMessage],
        rememberedFacts: String? = nil,
        confirmedProfile: PatientProfile? = nil,
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

        // Apply token budget to RAG chunks so the system prompt stays compact. processQuery has
        // already packed the context (see `packed`); packing is idempotent, so doing it again
        // here only matters for a caller that passes an unpacked context.
        let budgetedChunks = Self.applyContextBudget(
            context.chunks, budget: Self.contextTokenBudget, ratio: Self.wordsToTokensRatio
        )

        // The confirmed, cross-conversation profile — durable baseline, persists across chats.
        // Omitted entirely when nothing has been confirmed yet (e.g. a brand-new install), so a
        // blank profile produces the exact prompt this code produced before profiles existed.
        //
        // Placed in the STABLE part of the prompt — after the fixed persona and constraints,
        // before the per-turn sections (retrieval note, session facts) and before the retrieved
        // chunks further down. The profile only changes when the patient edits it or accepts a
        // proposal, so keeping it ahead of everything volatile lets the KV cache reuse the whole
        // prefix across turns instead of re-prefilling from the first personalized token.
        let formattedProfile = confirmedProfile.map { formatProfile($0, budget: Self.profileTokenBudget) } ?? ""
        let profileSection = formattedProfile.isEmpty ? "" : """

        Confirmed patient profile (persisted, may be from an earlier conversation):
        \(formattedProfile)
        """

        // Facts the user has stated earlier this session (name, allergies, wound location, …).
        // Injected so they survive past the short history window; omitted entirely when empty.
        let memorySection = (rememberedFacts?.isEmpty == false) ? """

        Known facts about this patient (stated earlier in this conversation — use them, and do NOT ask for information already listed here):
        \(rememberedFacts!)
        """ : ""

        // Two memory tiers can disagree (e.g. the profile says one wound location, the
        // conversation states a newer one) — tell the model which one to trust.
        let conflictInstruction = (!profileSection.isEmpty && !memorySection.isEmpty) ? """

        If the confirmed patient profile and the facts stated earlier in this conversation conflict, trust the conversation facts as more current.
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

        // The system prompt is assembled from three segments, in increasing order of how often
        // they change. Keeping that order — and keeping the invariant block genuinely invariant
        // — is what makes a prefix KV cache possible later; until then it at least stops the
        // prompt from being one 2k-token string that has to be re-read to be understood.
        //
        //   1. languageDirective — changes only when the user switches language
        //   2. Self.invariantSystemPrompt — never changes at runtime
        //   3. everything below — changes every single turn (context, facts, confidence)
        let systemPrompt = """
        LANGUAGE: \(languageInstruction)

        \(Self.invariantSystemPrompt)\(profileSection)\(contextLanguageNote)\(noContextInstruction)\(memorySection)\(conflictInstruction)

        Retrieved Medical Context:
        \(formatContextChunks(budgetedChunks))

        Sources:
        \(formatSources(context.sources))

        Confidence Score: \(String(format: "%.0f%%", context.confidenceScore * 100))

        REMINDER — \(languageInstruction)
        """

        // Trim history by token budget rather than turn count, so a few long answers cost the
        // same prefill as many short ones. Older context is less useful for a 3B model and
        // significantly increases prefill time.
        let budgetedHistory = applyHistoryBudget(history, budget: Self.historyTokenBudget)

        return EnrichedPrompt(systemPrompt: systemPrompt, userMessage: userQuery, history: budgetedHistory)
    }

    /// Segment 2 of the system prompt: the fixed persona and safety constraints, which never vary
    /// at runtime.
    ///
    /// Re-read by the model on every turn, so its length is a per-turn prefill tax. Slimmed from
    /// 473 to about 315 whitespace words — roughly 270 fewer tokens per turn at Qwen 3.5's
    /// measured 1.72 tokens per word — by removing restatement, not requirements. The one rule
    /// deleted outright (answer common health questions from general knowledge when nothing was
    /// retrieved) is carried by `noContextInstruction`, which is injected precisely when it applies.
    ///
    /// The language directive deliberately does NOT appear here. It used to be stated three
    /// times (opening line, a constraint bullet, and the closing reminder); the middle copy was
    /// dropped because the opening and the reminder are the two positions a small model
    /// actually attends to. `LanguageDriftTests` / `OutputGuardRailVietnameseTests` are the
    /// regression check if this turns out to have been load-bearing.
    ///
    /// SAFETY-CRITICAL. Any edit changes model behaviour and must be re-validated against
    /// Docs/BE/Adversarial-Chat-Test-Script.md before shipping — a shorter prompt that drops a
    /// constraint is not an optimisation. Internal, not private, so SystemPromptConstraintTests
    /// can assert every safety rule is still present after any future slimming.
    static let invariantSystemPrompt = """
        You are a warm, supportive medical information assistant for colorectal cancer patients
        and their families, many of them elderly or recovering from surgery. Speak kindly and
        naturally, as a caring nurse would. You provide educational health information.

        CONVERSATION:
        - Respond naturally to greetings, thanks and small talk. Patients talk to you like a
          person, not a search box.
        - When someone shares a personal detail ("I'm John", "my surgery was last week"),
          acknowledge it warmly and remember it for the rest of the conversation. Never reject a
          message for not being a clinical question.
        - Treat vague follow-ups ("is that normal?", "should I worry?") as continuing the current
          health topic.

        CONSTRAINTS:
        - You are NOT a licensed physician: no diagnosis, no treatment plans.
        - Prefer the Retrieved Medical Context below and cite it as your primary source.
        - That context describes colorectal care in general; it is NOT this patient's record.
          Never state or imply they have had a procedure, have a stoma, or are on a treatment
          unless they said so or it appears under known facts.
        - Keep guidance about anything they have not mentioned conditional ("if you have a
          stoma…"), warning signs included — a red flag specific to one procedure must be framed
          for that procedure, not issued as a general alarm.
        - If the answer would differ materially by procedure, ask one short clarifying question
          rather than guessing.
        - If a question is genuinely unrelated to health or care (coding, maths, trivia), do not
          refuse coldly: note briefly that you are here to support their health and recovery, then
          invite a health question.
        - ALWAYS cite your sources for medical information.
        - Never recommend specific dosages confidently.
        - If the user describes emergency symptoms, immediately tell them to call emergency services.
        - When giving medical information, add a short disclaimer to consult their healthcare provider (not needed for greetings or small talk).
        """

    /// Formats the confirmed profile as compact bullet lines, prioritized identity → clinical
    /// basics → clinical lists → care guidance → free-text summary, and truncated to `budget`
    /// (word-count estimate, same approach as `applyContextBudget`) so the least
    /// turn-to-turn-useful fields (report summary, then care notes/warning signs) are the
    /// first dropped when the profile has grown large.
    private func formatProfile(_ profile: PatientProfile, budget: Int) -> String {
        func line(_ label: String, _ value: String) -> String? {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return "- \(label): \(trimmed)"
        }
        func bulletList(_ label: String, _ items: [String]) -> String? {
            guard !items.isEmpty else { return nil }
            return "- \(label): " + items.joined(separator: "; ")
        }

        var sections: [String] = []
        if !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("- Name: \(profile.name)")
        }
        if profile.age > 0 { sections.append("- Age: \(profile.age)") }
        if let l = line("Gender", profile.gender) { sections.append(l) }
        if let l = line("Diagnosis", profile.diagnosis) { sections.append(l) }
        if let l = line("Procedure", profile.procedure) { sections.append(l) }
        if let l = line("Recovery stage", profile.recoveryStage) { sections.append(l) }
        if let location = profile.currentWoundLocation, let l = line("Current wound location", location) {
            sections.append(l)
        }
        if let l = bulletList("Allergies", profile.allergies) { sections.append(l) }
        if let l = bulletList("Medications", profile.medications) { sections.append(l) }
        if let l = bulletList("Conditions", profile.conditions) { sections.append(l) }
        if let l = bulletList("Care notes", profile.careNotes) { sections.append(l) }
        if let l = bulletList("Warning signs", profile.warningSigns) { sections.append(l) }
        // Excerpted, not included whole. A clinician report summary is prose and can run to
        // hundreds of words — long enough to consume the entire budget on its own and push out
        // the structured fields above it, which are what actually change the model's answer.
        if let l = line("Report summary", Self.excerpt(profile.reportSummary, words: Self.reportSummaryWordCap)) {
            sections.append(l)
        }

        var usedTokens = 0
        var selected: [String] = []
        for section in sections {
            let estimate = section.split { $0.isWhitespace }.count
            if usedTokens + estimate > budget { break }
            usedTokens += estimate
            selected.append(section)
        }

        return selected.joined(separator: "\n")
    }

    /// The profile fields worth biasing retrieval toward: what the patient has, what was done to
    /// them, and where their wound is. These are the terms that decide whether a chunk is about
    /// this patient's situation at all — "leakage" retrieves very different guidance for a
    /// colostomy than for a surgical incision.
    ///
    /// Deliberately not the whole profile. Care notes and warning signs are *advice already given
    /// to* the patient rather than descriptions of their condition, and OR-ing them into the FTS
    /// query would match chunks that merely repeat that advice. Empty for a blank profile, which
    /// leaves retrieval byte-identical to its behavior before profiles existed.
    ///
    /// Values are passed as whole phrases: `SQLiteRetriever.tokenizeForFTS` splits, strips
    /// punctuation, and drops stopwords, so no pre-tokenizing is needed here.
    ///
    /// Internal rather than private so `PatientProfilePersonalizationTests` can assert the
    /// blank-profile case returns nothing — the guard that keeps retrieval unchanged for a
    /// patient who has never filled in a profile.
    static func retrievalTerms(_ profile: PatientProfile) -> [String] {
        let candidates = [profile.diagnosis, profile.procedure, profile.currentWoundLocation ?? ""]
        var seen = Set<String>()
        return candidates
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// First `words` whitespace-separated words of `text`, with an ellipsis when truncated.
    /// Returns "" unchanged for empty input so callers can keep using emptiness as "omit this".
    private static func excerpt(_ text: String, words: Int) -> String {
        let parts = text.split { $0.isWhitespace }
        guard parts.count > words else { return text }
        return parts.prefix(words).joined(separator: " ") + " […]"
    }

    /// Packs relevance-ranked chunks into `budget` estimated tokens, in two passes:
    ///
    ///   1. every chunk that fits whole, in rank order — a chunk that does not fit is skipped,
    ///      so it costs only itself;
    ///   2. whatever budget is left goes to the head of the highest-ranked chunk that was
    ///      skipped, kept at its own rank and marked as cut.
    ///
    /// This used to `break` on the first chunk that did not fit, which discarded every chunk
    /// behind it however small. Because the corpus contains chunks far larger than any sane
    /// budget (18% exceed 512 tokens; the largest is ~13.6k), a single oversized chunk landing
    /// at rank 1 emptied the whole context — and the model answered a medical question from
    /// parametric memory with no sources at all. Measured over the 209-query golden set, that
    /// happened on **22.5% of queries**, and only 1.52 of 5 retrieved chunks reached the model.
    /// The first fix spent the remainder on that oversized chunk *before* looking further, so a
    /// huge chunk at rank 1 still evicted every small chunk behind it; the partial fill now
    /// comes last.
    ///
    /// The result never exceeds `budget` under `estimateTokens(_:ratio:)`, which also makes
    /// packing idempotent. `static` and internal rather than private: it depends on no instance
    /// state, and a unit test can exercise it directly instead of standing up an orchestrator.
    static func applyContextBudget(_ chunks: [ContextChunk], budget: Int, ratio: Double) -> [ContextChunk] {
        guard budget > 0 else { return [] }

        var usedTokens = 0
        var fitsWhole = [Bool](repeating: false, count: chunks.count)
        var firstSkipped: Int?
        for (index, chunk) in chunks.enumerated() {
            let estimate = estimateTokens(chunk.content, ratio: ratio)
            if usedTokens + estimate <= budget {
                usedTokens += estimate
                fitsWhole[index] = true
            } else if firstSkipped == nil {
                firstSkipped = index
            }
        }

        // A chunk skipped in pass 1 still does not fit whole: the budget only filled up since.
        var partial: (index: Int, chunk: ContextChunk)?
        let remaining = budget - usedTokens
        if let index = firstSkipped,
           remaining >= minimumUsefulChunkTokens,
           let head = head(of: chunks[index].content, fittingTokens: remaining, ratio: ratio) {
            let chunk = chunks[index]
            partial = (
                index,
                ContextChunk(
                    id: chunk.id,
                    content: head,
                    section: chunk.section,
                    sourceID: chunk.sourceID,
                    relevanceScore: chunk.relevanceScore
                )
            )
        }

        return chunks.indices.compactMap { index in
            if fitsWhole[index] { return chunks[index] }
            if let partial, partial.index == index { return partial.chunk }
            return nil
        }
    }

    /// The retrieved context narrowed to what fits `budget`, with `sources` narrowed to the
    /// documents the surviving chunks came from (retrieval order preserved).
    static func packed(_ context: RetrievedContext, budget: Int, ratio: Double) -> RetrievedContext {
        let chunks = applyContextBudget(context.chunks, budget: budget, ratio: ratio)
        let documentsSeen = Set(chunks.map(\.sourceID))
        return RetrievedContext(
            chunks: chunks,
            confidenceScore: context.confidenceScore,
            sources: context.sources.filter { documentsSeen.contains($0.id) }
        )
    }

    /// Below this, a partial passage is more likely to mislead than to ground: a sentence or
    /// two torn out of a clinical document reads as authoritative while carrying no usable
    /// fact. Better to leave the budget unspent.
    private static let minimumUsefulChunkTokens = 80

    /// Appended to a cut passage so the model does not treat the end of the text as the end of
    /// the guidance. It is one whitespace word, and `head` pays for it.
    private static let truncationMarker = " […]"

    /// The longest head of `text` that, with the truncation marker, costs at most `tokens` under
    /// `estimateTokens` — or `nil` when not even one word fits.
    ///
    /// Words are counted exactly as `estimateTokens` counts them (any whitespace, same rounding),
    /// and the cut is made in the original string, so line breaks and list structure inside the
    /// head survive. An earlier version split on " " only: a passage with line breaks then held
    /// fewer "words" than the estimate saw, and the whole chunk could come back uncut and over
    /// budget.
    private static func head(of text: String, fittingTokens budget: Int, ratio: Double) -> String? {
        var allowedWords = Int(Double(budget) / ratio) - 1
        // Guard against floating-point rounding in the division: the bound is checked with the
        // exact arithmetic `estimateTokens` uses, counting the marker as one word.
        while allowedWords >= 1 && tokens(forWords: allowedWords + 1, ratio: ratio) > budget {
            allowedWords -= 1
        }
        guard allowedWords >= 1 else { return nil }

        var wordsSeen = 0
        var inWord = false
        for index in text.indices {
            if text[index].isWhitespace {
                if inWord && wordsSeen == allowedWords {
                    return String(text[..<index]) + truncationMarker
                }
                inWord = false
            } else if !inWord {
                inWord = true
                wordsSeen += 1
            }
        }
        // The text has no more than `allowedWords` words, so it was never over budget; the
        // packer only asks for heads of chunks that did not fit, and does not use this.
        return nil
    }

    /// Selects as many of the most recent messages as fit within `budget`, condensing assistant
    /// turns on the way in. Walks newest → oldest — the opposite of `applyContextBudget`, which
    /// walks a relevance-ranked list — because recency is what makes a past turn worth replaying,
    /// so the oldest messages are the ones to drop when the budget runs out.
    ///
    /// Only text is metered. An image attached to a past user turn is replayed untouched (the
    /// vision path in LLMService needs it) and its prefill cost is not visible to this budget.
    private func applyHistoryBudget(_ history: [ChatMessage], budget: Int) -> [ChatMessage] {
        var usedTokens = 0
        var selected: [ChatMessage] = []

        for message in history.reversed() {
            let replayable = Self.condenseForReplay(message)
            let estimate = Self.estimateTokens(replayable.content, ratio: Self.wordsToTokensRatio)
            if usedTokens + estimate > budget { break }
            usedTokens += estimate
            selected.append(replayable)
        }

        var ordered = Array(selected.reversed())
        // The cut can land between an assistant reply and the user turn it answered, leaving
        // history starting on an assistant message — a shape the chat template never sees in
        // real conversation. Drop that orphan so replayed history always opens with a user turn.
        if ordered.first?.role.lowercased() == "assistant" {
            ordered.removeFirst()
        }
        return ordered
    }

    /// Shortens an assistant turn to the gist before it is replayed. User turns are returned
    /// unchanged: they are short already, and they are the part the model most needs verbatim
    /// (symptoms, numbers, the exact question being followed up on).
    ///
    /// The assistant's own formatting is the first thing to go. Headings, bullet markers, and
    /// emphasis carry no information the model needs to continue the conversation, but they
    /// account for a large share of a long answer's tokens.
    private static func condenseForReplay(_ message: ChatMessage) -> ChatMessage {
        guard message.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "assistant"
        else { return message }

        let stripped = message.content
            // Leading markdown structure: "## ", "- ", "* ", "1. ", blockquotes.
            .replacingOccurrences(
                of: "(?m)^\\s*(#{1,6}|[-*+]|\\d+\\.|>)\\s+",
                with: "",
                options: .regularExpression
            )
            // Inline emphasis and code markers.
            .replacingOccurrences(of: "[*_`]", with: "", options: .regularExpression)
            // Collapse the whitespace the removals leave behind into single spaces.
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let words = stripped.split { $0.isWhitespace }
        guard words.count > assistantReplayWordCap else {
            return ChatMessage(
                role: message.role,
                content: stripped,
                sources: message.sources,
                imageData: message.imageData
            )
        }

        let condensed = words.prefix(assistantReplayWordCap).joined(separator: " ") + " […]"
        return ChatMessage(
            role: message.role,
            content: condensed,
            sources: message.sources,
            imageData: message.imageData
        )
    }

    /// Words-to-tokens ratio used to convert a cheap word count into a token estimate.
    ///
    /// Tokens per whitespace word for the model that is answering: its measured value
    /// (`ModelCatalog.wordsToTokensRatio`, produced by `Pipeline/tools/measure_token_ratio.py`)
    /// unless `InferenceTuning` pins one for a sweep. Tokenizers differ enough (Llama 3.2 1.61
    /// vs Phi-3.5 2.04 tokens/word on this corpus) that one global value would overshoot the
    /// budget on one model and starve the context on another.
    private static var wordsToTokensRatio: Double {
        tuning.wordsToTokensRatio ?? AppConfig.selectedModel.wordsToTokensRatio
    }

    /// Rough token estimate: whitespace words × `ratio`, rounded up. Deliberately not the real
    /// tokenizer — this runs on every turn for budgeting only, where being cheap matters more
    /// than being exact; the measured `ratio` is what makes the budgets mean tokens.
    ///
    /// It used to return the raw word count, which meant the "600-token" context budget was
    /// really letting through ~840 tokens and the "500-token" history budget ~700.
    static func estimateTokens(_ text: String, ratio: Double) -> Int {
        tokens(forWords: text.split { $0.isWhitespace }.count, ratio: ratio)
    }

    /// The one place the words → tokens arithmetic lives, so the packer's cut and the estimate
    /// can never round differently.
    private static func tokens(forWords words: Int, ratio: Double) -> Int {
        Int((Double(words) * ratio).rounded(.up))
    }


    private func formatContextChunks(_ chunks: [ContextChunk]) -> String {
        guard !chunks.isEmpty else {
            return "[No relevant medical context found]"
        }
        
        // One short label per chunk instead of a rule line plus a numbered heading: the model
        // needs to know where one passage ends and the next begins, not that this is passage
        // three of five. The old form spent tens of tokens per turn on that framing.
        return chunks.map { chunk in
            let sectionLabel = chunk.section.isEmpty ? "General" : chunk.section
            return "[\(sectionLabel)]\n\(chunk.content)"
        }.joined(separator: "\n\n")
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
