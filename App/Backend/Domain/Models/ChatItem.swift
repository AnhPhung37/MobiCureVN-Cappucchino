import Foundation

struct ChatItem: Identifiable, Sendable {
    let id: UUID
    let conversationId: UUID
    let role: String
    let content: String
    let date: Date
    let sources: [MedicalSource]
    let imageData: [Data]
    /// Mirrors `ChatMessage.profileUpdateProposals` — carried through so the live message list
    /// can render the inline confirmation card. Not persisted by `ChatHistoryRepository`, so
    /// this is always empty on items reloaded from history; `ProfileUpdateRepository` is the
    /// durable copy.
    let profileUpdateProposals: [ProposedProfileUpdate]

    init(
        id: UUID = UUID(),
        conversationId: UUID = UUID(),
        role: String,
        content: String,
        date: Date = Date(),
        sources: [MedicalSource] = [],
        imageData: [Data] = [],
        profileUpdateProposals: [ProposedProfileUpdate] = []
    ) {
        self.id = id
        self.conversationId = conversationId
        self.role = role
        self.content = content
        self.date = date
        self.sources = sources
        self.imageData = imageData
        self.profileUpdateProposals = profileUpdateProposals
    }
}
