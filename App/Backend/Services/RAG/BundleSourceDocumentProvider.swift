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

    func pageIndex(for source: MedicalSource) async -> Int? {
        // `page_start` is not populated by the ingestion pipeline, so `page` is usually 0.
        // Trust it when present; otherwise locate the excerpt by text search.
        guard let url = documentURL(for: source) else { return nil }
        if source.page > 0 { return source.page - 1 }

        let queries = Self.searchWindows(from: source.excerpt)
        guard !queries.isEmpty else { return nil }

        // A full-text search over a large guideline (200+ pages) takes noticeable time, so it
        // runs off the main actor on its own PDFDocument instance.
        return await Task.detached(priority: .userInitiated) {
            guard let document = PDFDocument(url: url) else { return nil }
            for query in queries {
                let matches = document.findString(query, withOptions: [.caseInsensitive, .diacriticInsensitive])
                if let page = matches.first?.pages.first {
                    return document.index(for: page)
                }
            }
            return nil
        }.value
    }

    /// Overlapping five-word phrases from the excerpt. The excerpt is Markdown-stripped text
    /// whose line breaks differ from the PDF's, so a phrase spanning a line or a stripped symbol
    /// fails to match; trying several short phrases finds the passage in ~90% of chunks.
    static func searchWindows(from excerpt: String, length: Int = 5, stride: Int = 3, limit: Int = 8) -> [String] {
        let words = excerpt
            .replacingOccurrences(of: "…", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { $0.rangeOfCharacter(from: .letters) != nil }
        var windows: [String] = []
        var start = 0
        // The excerpt is truncated mid-word, so its final word is never used.
        while start + length < words.count, windows.count < limit {
            windows.append(words[start..<(start + length)].joined(separator: " "))
            start += stride
        }
        return windows
    }
}
