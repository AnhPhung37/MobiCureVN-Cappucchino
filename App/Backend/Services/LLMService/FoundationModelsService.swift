//
//  FoundationModelsService.swift
//  MobiCureVN
//

import Foundation
import FoundationModels

/// `LLMServiceProtocol` backed by Apple's on-device system language model.
///
/// Unlike `LLMService`, nothing here is downloaded or held resident by the app: the model is
/// owned by the OS, so short utility calls (language classification, fact extraction) can run
/// through it without evicting the multi-GB MLX chat model or competing for its memory.
///
/// Availability is *not* a build-time property — the model can be missing because the device
/// doesn't support Apple Intelligence, the user turned it off, or the OS is still fetching the
/// assets — so callers must check `isAvailable` before every use and fall back. `AppConfig`
/// does exactly that in `utilityLLMService`.
///
/// Text-only: `LLMRequest.images` are ignored. Image-bearing requests belong on the MLX VLM
/// path (`WoundAnalysisService`).
@available(iOS 26.0, *)
nonisolated final class FoundationModelsService: @unchecked Sendable, LLMServiceProtocol {

    /// Whether the system model can serve a request *right now*. Re-checked per call because
    /// the user can toggle Apple Intelligence, and asset download completes, while we run.
    static var isAvailable: Bool {
        switch SystemLanguageModel.default.availability {
        case .available:
            logAvailabilityChange("available")
            return true
        case .unavailable(let reason):
            logAvailabilityChange("unavailable — \(reason)")
            return false
        @unknown default:
            logAvailabilityChange("unavailable — unrecognized availability case")
            return false
        }
    }

    /// `isAvailable` is polled on every utility call, so log only when the answer flips —
    /// otherwise a device without Apple Intelligence floods the console.
    private static var lastLoggedAvailability: String?
    private static func logAvailabilityChange(_ state: String) {
        guard lastLoggedAvailability != state else { return }
        lastLoggedAvailability = state
        print("FoundationModelsService: system model \(state)")
    }

    // MARK: - LLMServiceProtocol

    func stream(request: LLMRequest) -> AsyncStream<String> {
        AsyncStream<String>(bufferingPolicy: .unbounded) { continuation in
            let task = Task {
                // Each request is self-contained — callers trim and enrich the history
                // themselves — so a fresh session is built per request, seeded with that
                // history rather than carrying its own across calls.
                let session = Self.makeSession(
                    instructions: request.systemPrompt,
                    history: request.conversationHistory
                )
                let prompt = request.userMessage

                do {
                    // Snapshots are cumulative — the protocol's consumers concatenate what they
                    // receive, so only the newly appended text is yielded.
                    var emitted = ""
                    for try await partial in session.streamResponse(to: prompt) {
                        if Task.isCancelled { break }
                        let snapshot = partial.content
                        let delta = Self.delta(previous: emitted, snapshot: snapshot)
                        emitted = snapshot
                        if !delta.isEmpty { continuation.yield(delta) }
                    }
                } catch {
                    // Guardrail refusals, context-window overflow and asset errors all land here.
                    // Yield nothing: callers treat an empty reply as "no answer" and fall back to
                    // their deterministic path, which is safer than emitting an error string that
                    // could be parsed as a result.
                    print("FoundationModelsService: generation failed — \(error)")
                }

                continuation.finish()
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Private

    /// Builds a session carrying `instructions` in the developer role and `history` as real
    /// prior turns.
    ///
    /// This previously flattened history into the prompt as literal `"User: …\nAssistant: …"`
    /// text. That reads to the model as a single user turn *quoting a transcript*, not as a
    /// conversation: role boundaries become ordinary words the model can ignore, contradict, or
    /// continue in the wrong voice, and any user text containing "Assistant:" is indistinguishable
    /// from a real turn. Seeding a `Transcript` keeps each turn in its own role — the same thing
    /// the MLX path has always done via `Chat.Message` in `LLMService.buildChat`.
    private static func makeSession(
        instructions: String,
        history: [ChatMessage]
    ) -> LanguageModelSession {
        var entries: [Transcript.Entry] = []

        let trimmedInstructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedInstructions.isEmpty {
            entries.append(.instructions(Transcript.Instructions(
                segments: [.text(Transcript.TextSegment(content: trimmedInstructions))],
                toolDefinitions: []
            )))
        }

        for message in history {
            let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { continue }
            let segment = Transcript.Segment.text(Transcript.TextSegment(content: content))
            let role = message.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            // Only user/assistant turns belong in a transcript; anything else is coerced to a
            // prompt so no unknown role reaches the model — mirrors `LLMService.buildChat`.
            if role == "assistant" {
                entries.append(.response(Transcript.Response(assetIDs: [], segments: [segment])))
            } else {
                entries.append(.prompt(Transcript.Prompt(segments: [segment])))
            }
        }

        // `init(transcript:)` and `init(instructions:)` are mutually exclusive — instructions
        // travel as the transcript's first entry above, which is the same thing the string
        // initializer does internally.
        return LanguageModelSession(transcript: Transcript(entries: entries))
    }

    /// New text in `snapshot` relative to what was already emitted. Streaming is append-only in
    /// practice; if a snapshot ever rewrites earlier text we can't retract what the consumer
    /// already has, so we emit everything past the common prefix and accept the seam.
    private static func delta(previous: String, snapshot: String) -> String {
        if snapshot.hasPrefix(previous) {
            return String(snapshot.dropFirst(previous.count))
        }
        let common = snapshot.commonPrefix(with: previous)
        return String(snapshot.dropFirst(common.count))
    }
}

// MARK: - StructuredLLMService

@available(iOS 26.0, *)
extension FoundationModelsService: StructuredLLMService {

    /// Guided generation: the decoder is constrained to `Content`'s schema, so the result always
    /// decodes. No `<think>` stripping, no brace-balancing to find the JSON, no tolerant decoding
    /// of string-or-number — the failure modes those guard against cannot occur here.
    func respond<Content: Generable>(
        to prompt: String,
        instructions: String,
        generating: Content.Type
    ) async throws -> Content {
        let session = Self.makeSession(instructions: instructions, history: [])
        let response = try await session.respond(
            to: prompt,
            generating: Content.self,
            // Extraction, not composition: the same message must yield the same facts on every
            // run, so sampling is pinned to greedy rather than left at the framework default.
            options: GenerationOptions(sampling: .greedy)
        )
        return response.content
    }
}
