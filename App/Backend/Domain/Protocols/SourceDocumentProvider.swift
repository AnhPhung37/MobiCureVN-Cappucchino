import Foundation

/// Resolves a citation to the original document it was retrieved from, so the patient can read
/// the passage in context. Documents are bundled with the app — nothing is fetched.
protocol SourceDocumentProvider {
    /// Local file URL of the source PDF, or nil when that document isn't bundled.
    func documentURL(for source: MedicalSource) -> URL?
    /// Locates the cited passage in the document, or nil when it can't be located.
    func locate(_ source: MedicalSource) async -> SourceLocation?
}
