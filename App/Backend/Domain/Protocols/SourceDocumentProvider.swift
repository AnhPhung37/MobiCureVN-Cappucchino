import Foundation

/// Resolves a citation to the original document it was retrieved from, so the patient can read
/// the passage in context. Documents are bundled with the app — nothing is fetched.
protocol SourceDocumentProvider {
    /// Local file URL of the source PDF, or nil when that document isn't bundled.
    func documentURL(for source: MedicalSource) -> URL?
    /// Zero-based index of the PDF page the cited passage is on, or nil when it can't be located.
    func pageIndex(for source: MedicalSource) async -> Int?
}
