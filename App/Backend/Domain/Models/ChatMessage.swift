import Foundation

public struct ChatMessage: Sendable {
    public let role: String
    public let content: String
    public let sources: [MedicalSource]
    public let imageData: [Data]
    /// AI-proposed profile updates surfaced by this turn, awaiting patient confirmation. Only
    /// ever non-empty on the assistant message that triggered them, and only for the lifetime
    /// of this in-memory session — see `ProfileUpdateRepository` for the durable copy.
    public let profileUpdateProposals: [ProposedProfileUpdate]

    public init(
        role: String,
        content: String,
        sources: [MedicalSource] = [],
        imageData: [Data] = [],
        profileUpdateProposals: [ProposedProfileUpdate] = []
    ) {
        self.role = role
        self.content = content
        self.sources = sources
        self.imageData = imageData
        self.profileUpdateProposals = profileUpdateProposals
    }
}
