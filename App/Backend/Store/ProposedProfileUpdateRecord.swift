import Foundation
import SwiftData

/// Persisted (not just in-memory) so a proposal survives the patient backgrounding the app
/// before acting on it — see `SwiftDataProfileUpdateRepository`.
@Model
final class ProposedProfileUpdateRecord {
    @Attribute(.unique) var id: UUID
    var conversationId: UUID
    /// Raw value of `ProfileUpdateExtractor.FieldProposal.Field`.
    var field: String
    var newValue: String
    var previousValue: String?
    var isHighStakes: Bool
    var sourceExcerpt: String
    var createdAt: Date
    /// Raw value of `ProposedProfileUpdate.Status`.
    var status: String

    init(
        id: UUID,
        conversationId: UUID,
        field: String,
        newValue: String,
        previousValue: String?,
        isHighStakes: Bool,
        sourceExcerpt: String,
        createdAt: Date,
        status: String
    ) {
        self.id = id
        self.conversationId = conversationId
        self.field = field
        self.newValue = newValue
        self.previousValue = previousValue
        self.isHighStakes = isHighStakes
        self.sourceExcerpt = sourceExcerpt
        self.createdAt = createdAt
        self.status = status
    }
}
