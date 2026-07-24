import Foundation

/// A durable, per-conversation store of facts the user has stated about themselves during
/// a chat session — name, age, allergies, current wound location, medications, etc.
///
/// Purpose: the LLM prompt only carries the last `maxHistoryTurns` turns (see
/// `MedicalChatOrchestrator`), so a fact mentioned early in a session would otherwise be
/// forgotten once it scrolls out of that window. Facts captured here are re-injected into
/// the system prompt on EVERY turn, so they persist for the whole conversation regardless of
/// how far back they were first mentioned.
///
/// Scope & lifetime: keyed by `conversationId`. `ChatViewModel.clearConversation()` mints a
/// fresh conversation id, so starting a new chat naturally starts with an empty fact set.
/// This is an in-memory store (a handful of short strings per conversation) — deliberately
/// cheap on the 16GB iPad Air budget and requiring no SwiftData schema change. It is the seed
/// of a future persistent user profile; when that lands, the same `SessionFact` shape can be
/// lifted out and persisted.
///
/// Facts are stored in English, matching the layer that populates them: the orchestrator only
/// ever sees English text (ChatService translates the user's original-language input to
/// English before calling it), so extraction, storage, and system-prompt injection are all
/// single-language.
///
/// An actor because it is written from the background generation task and read while building
/// each prompt; the isolation keeps concurrent turns from racing on the fact dictionary.
actor SessionFactStore {

    /// A single remembered fact. `key` is a stable, lowercase category ("name", "age",
    /// "allergy", "wound_location", "medication") so a later turn updating the same category
    /// overwrites rather than duplicates; `value` is the concise English fact itself.
    struct SessionFact: Sendable, Equatable {
        let key: String
        let value: String
    }

    /// Cap per conversation so a long or adversarial session can't grow the injected prompt
    /// without bound. Oldest facts are evicted first once the cap is exceeded.
    private static let maxFactsPerConversation = 12

    /// conversationId → ordered facts (insertion order; oldest first for eviction).
    private var factsByConversation: [UUID: [SessionFact]] = [:]

    /// Merge newly extracted facts into a conversation's set. A fact whose `key` already
    /// exists is updated in place (latest statement wins — e.g. the user corrects their age);
    /// genuinely new keys are appended. Empty keys/values are ignored.
    func merge(_ newFacts: [SessionFact], into conversationId: UUID) {
        guard !newFacts.isEmpty else { return }
        var facts = factsByConversation[conversationId] ?? []

        for incoming in newFacts {
            let key = incoming.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = incoming.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty else { continue }

            if let existingIndex = facts.firstIndex(where: { $0.key == key }) {
                facts[existingIndex] = SessionFact(key: key, value: value)
            } else {
                facts.append(SessionFact(key: key, value: value))
            }
        }

        // Evict oldest facts beyond the cap so the injected block stays bounded.
        if facts.count > Self.maxFactsPerConversation {
            facts.removeFirst(facts.count - Self.maxFactsPerConversation)
        }

        factsByConversation[conversationId] = facts
    }

    /// All facts remembered for a conversation, oldest first.
    func facts(for conversationId: UUID) -> [SessionFact] {
        factsByConversation[conversationId] ?? []
    }

    /// Facts formatted as a compact block for injection into the system prompt, or `nil` when
    /// nothing has been remembered yet (so the caller can omit the section entirely).
    func promptBlock(for conversationId: UUID) -> String? {
        let facts = factsByConversation[conversationId] ?? []
        guard !facts.isEmpty else { return nil }
        return facts.map { "- \(Self.label(for: $0.key)): \($0.value)" }.joined(separator: "\n")
    }

    /// Drop everything remembered for a conversation (e.g. the user clears the chat and the
    /// caller wants to proactively free the slot; harmless if the id is unknown).
    func reset(_ conversationId: UUID) {
        factsByConversation[conversationId] = nil
    }

    // MARK: - Private

    /// Humanize a snake_case key for the prompt block ("wound_location" → "Wound location").
    private static func label(for key: String) -> String {
        let spaced = key.replacingOccurrences(of: "_", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }
}
