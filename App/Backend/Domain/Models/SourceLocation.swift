import Foundation

/// Where a citation's excerpt was found within its source document.
struct SourceLocation: Equatable {
    /// Zero-based page index.
    let pageIndex: Int
    /// The exact phrase that matched, for highlighting on the page; nil when the page was
    /// known outright (`source.page`) rather than located by text search.
    let matchedText: String?
}
