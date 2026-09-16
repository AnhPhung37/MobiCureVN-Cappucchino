import Foundation
import PDFKit

/// Serves the source PDFs bundled under `Resources/SourceDocuments`, each named by its
/// registry `doc_id` (the `MedicalSource.id`).
struct BundleSourceDocumentProvider: SourceDocumentProvider {

    private let bundle: Bundle

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    func documentURL(for source: MedicalSource) -> URL? {
        bundle.url(forResource: source.id, withExtension: "pdf")
    }

    func locate(_ source: MedicalSource) async -> SourceLocation? {
        // `page_start` is not populated by the ingestion pipeline, so `page` is usually 0.
        // Trust it when present; otherwise locate the excerpt by text search.
        guard let url = documentURL(for: source) else { return nil }
        if source.page > 0 { return SourceLocation(pageIndex: source.page - 1, matchedText: nil) }

        let queries = Self.searchWindows(from: source.excerpt)
        guard !queries.isEmpty else { return nil }

        // A full-text search over a large guideline (200+ pages) takes noticeable time, so it
        // runs off the main actor on its own PDFDocument instance.
        return await Task.detached(priority: .userInitiated) {
            guard let document = PDFDocument(url: url) else { return nil }
            for query in queries {
                let matches = document.findString(query, withOptions: [.caseInsensitive, .diacriticInsensitive])
                if let page = matches.first?.pages.first {
                    return SourceLocation(pageIndex: document.index(for: page), matchedText: query)
                }
            }
            return nil
        }.value
    }

    /// Overlapping five-word phrases from the excerpt. The excerpt is Markdown-stripped text
    /// whose line breaks differ from the PDF's, so a phrase spanning a line or a stripped symbol
    /// fails to match; trying several short phrases finds the passage in ~90% of chunks.
    static func searchWindows(from excerpt: String, length: Int = 5, stride: Int = 3, limit: Int = 8) -> [String] {
        // Only a truncated excerpt (SQLiteRetriever appends "…" when it cut the chunk) has a
        // mid-word final word; a short, complete excerpt keeps all of its words as usable.
        let isTruncated = excerpt.hasSuffix("…")
        let words = excerpt
            .replacingOccurrences(of: "…", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { $0.rangeOfCharacter(from: .letters) != nil }
        let usableCount = isTruncated ? words.count - 1 : words.count
        var windows: [String] = []
        var start = 0
        while start + length <= usableCount, windows.count < limit {
            windows.append(words[start..<(start + length)].joined(separator: " "))
            start += stride
        }
        return windows
    }
}
