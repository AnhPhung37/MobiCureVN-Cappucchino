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
                let instructions = request.systemPrompt
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // Instructions carry the developer prompt; the session's own transcript stays
                // empty because we build a fresh session per request (each request is
                // self-contained and already carries the history it wants).
                let session = instructions.isEmpty
                    ? LanguageModelSession()
                    : LanguageModelSession(instructions: instructions)

                let prompt = Self.buildPrompt(
                    history: request.conversationHistory,
                    user: request.userMessage
                )

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

    /// Flatten prior turns into the prompt. `LanguageModelSession` normally keeps history in its
    /// own transcript, but `LLMRequest` is the source of truth here (callers trim and enrich the
    /// history themselves), so each request gets a fresh session and carries its context inline.
    private static func buildPrompt(history: [ChatMessage], user: String) -> String {
        let turns = history.compactMap { msg -> String? in
            let content = msg.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return nil }
            let role = msg.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return role == "assistant" ? "Assistant: \(content)" : "User: \(content)"
        }

        guard !turns.isEmpty else { return user }
        return turns.joined(separator: "\n") + "\nUser: \(user)"
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
