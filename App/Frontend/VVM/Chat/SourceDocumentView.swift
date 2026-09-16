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
    /// Finds the zero-based page of the cited passage; nil when it can't be located.
    let locatePage: (MedicalSource) async -> Int?

    @Environment(\.dismiss) private var dismiss
    @State private var pageIndex: Int?
    @State private var isLocating = true

    @AppStorage(AppLanguage.storageKey) private var appLanguageRaw = AppLanguage.vietnamese.rawValue
    private var appLanguage: AppLanguage { AppLanguage(rawValue: appLanguageRaw) ?? .vietnamese }
    private func t(_ key: String) -> String { key.localized(for: appLanguage) }

    var body: some View {
        NavigationStack {
            PDFKitView(url: document.url, pageIndex: pageIndex)
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
                    pageIndex = await locatePage(document.source)
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
                } else if let pageIndex {
                    Text(String(format: t("Tr. %lld"), pageIndex + 1))
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

            if !isLocating && pageIndex == nil {
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
        view.go(to: page)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        /// Jump only once per located page so the patient's own scrolling isn't undone.
        var shownPageIndex: Int?
    }
}
