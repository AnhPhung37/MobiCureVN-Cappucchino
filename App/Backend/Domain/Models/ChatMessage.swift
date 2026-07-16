import Foundation

public struct ChatMessage: Sendable {
    public let role: String
    public let content: String
    public let sources: [MedicalSource]
    public let imageData: [Data]

    public init(role: String, content: String, sources: [MedicalSource] = [], imageData: [Data] = []) {
        self.role = role
        self.content = content
        self.sources = sources
        self.imageData = imageData
    }
}
