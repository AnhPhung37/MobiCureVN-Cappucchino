//
//  SourceDocumentView.swift
//  MobiCureVN
//

import PDFKit
import SwiftUI

/// A citation opened from a `CitationCard`: the source and the bundled PDF it came from.
struct PresentedSourceDocument: Identifiable {
    let source: MedicalSource
    let url: URL
    var id: String { source.id }
}

/// Full-document preview of a cited source, scrolled to the cited passage once it is located.
struct SourceDocumentView: View {

    let document: PresentedSourceDocument
    /// Locates the cited passage; nil when it can't be found.
    let locate: (MedicalSource) async -> SourceLocation?

    @Environment(\.dismiss) private var dismiss
    @State private var location: SourceLocation?
    @State private var isLocating = true

    @AppStorage(AppLanguage.storageKey) private var appLanguageRaw = AppLanguage.vietnamese.rawValue
    private var appLanguage: AppLanguage { AppLanguage(rawValue: appLanguageRaw) ?? .vietnamese }
    private func t(_ key: String) -> String { key.localized(for: appLanguage) }

    var body: some View {
        NavigationStack {
            PDFKitView(
                url: document.url,
                pageIndex: location?.pageIndex,
                matchedText: location?.matchedText,
                excerpt: document.source.excerpt
            )
                .ignoresSafeArea(edges: .bottom)
                .safeAreaInset(edge: .bottom) { excerptPanel }
                .navigationTitle(document.source.documentName)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .appFont(size: 22)
                                .foregroundColor(Color(.tertiaryLabel))
                        }
                        .accessibilityLabel(t("Đóng"))
                    }
                }
                .task {
                    location = await locate(document.source)
                    isLocating = false
                }
        }
    }

    /// The cited passage, so the patient knows what to look for on the page.
    private var excerptPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "text.quote")
                    .appFont(size: 12, weight: .semibold)
                    .foregroundColor(.accentColor)
                Text(t("Đoạn được trích dẫn"))
                    .appFont(size: 12, weight: .semibold)
                    .foregroundColor(Color(.secondaryLabel))
                Spacer()
                if isLocating {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(t("Đang tìm đoạn trích…"))
                } else if let location {
                    Text(String(format: t("Tr. %lld"), location.pageIndex + 1))
                        .appFont(size: 11, weight: .medium)
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                }
            }

            Text(document.source.excerpt)
                .appFont(size: 13)
                .foregroundColor(Color(.label))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            if !isLocating && location == nil {
                Text(t("Không tìm thấy vị trí chính xác của đoạn này trong tài liệu."))
                    .appFont(size: 11)
                    .foregroundColor(Color(.secondaryLabel))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - PDFKit bridge

private struct PDFKitView: UIViewRepresentable {
    let url: URL
    let pageIndex: Int?
    /// The phrase that located this page, when found by search rather than a known
    /// `source.page` — the starting anchor the highlight is grown outward from.
    let matchedText: String?
    /// The full cited passage, so the highlight can be extended to cover all of it rather
    /// than just the anchor phrase.
    let excerpt: String

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.document = PDFDocument(url: url)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        guard let pageIndex,
              pageIndex != context.coordinator.shownPageIndex,
              let page = view.document?.page(at: pageIndex) else { return }
        context.coordinator.shownPageIndex = pageIndex

        if let matchedText, let selection = Self.selection(forExcerpt: excerpt, anchor: matchedText, on: page) {
            selection.color = .systemYellow
            view.highlightedSelections = [selection]
            view.go(to: selection)
        } else {
            view.go(to: page)
        }
    }

    /// Builds one selection spanning the whole cited passage: re-finds the anchor phrase that
    /// located this page (the search that found it ran off the main thread against a separate
    /// `PDFDocument` instance of the same file, whose `PDFSelection` results aren't valid
    /// against this one — but both instances parse identical page text, so it reliably
    /// re-matches here), then walks forward through the excerpt's later word-windows to find how
    /// far the passage extends and grows the highlight to cover that whole span.
    private static func selection(forExcerpt excerpt: String, anchor: String, on page: PDFPage) -> PDFSelection? {
        guard let pageText = page.string as NSString? else { return nil }
        let anchorRange = pageText.range(of: anchor, options: [.caseInsensitive, .diacriticInsensitive])
        guard anchorRange.location != NSNotFound else { return nil }

        var end = anchorRange
        let tailStart = anchorRange.location + anchorRange.length
        if tailStart < pageText.length {
            let tail = NSRange(location: tailStart, length: pageText.length - tailStart)
            let laterWindows = BundleSourceDocumentProvider.searchWindows(from: excerpt, limit: 200)
            for window in laterWindows.reversed() {
                let found = pageText.range(of: window, options: [.caseInsensitive, .diacriticInsensitive], range: tail)
                if found.location != NSNotFound {
                    end = found
                    break
                }
            }
        }

        let combined = NSRange(location: anchorRange.location, length: (end.location + end.length) - anchorRange.location)
        return page.selection(for: combined)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        /// Jump only once per located page so the patient's own scrolling isn't undone.
        var shownPageIndex: Int?
    }
}
