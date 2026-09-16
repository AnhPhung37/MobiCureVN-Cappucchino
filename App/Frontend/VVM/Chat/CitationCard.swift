//
//  CitationCard.swift
//  MobiCureVN
//
//  Created by Anh Phung on 4/24/26.
//

import SwiftUI

/// One source behind an assistant reply: its title, document and page, and — when the PDF is
/// bundled — a tap target that opens it.
struct CitationCard: View {

    let source: MedicalSource
    /// Opens the source PDF; nil when the document isn't bundled, in which case the row is
    /// static with no tap action.
    var onOpenDocument: (() -> Void)? = nil

    @AppStorage(AppLanguage.storageKey) private var appLanguageRaw = AppLanguage.vietnamese.rawValue
    private var appLanguage: AppLanguage { AppLanguage(rawValue: appLanguageRaw) ?? .vietnamese }

    var body: some View {
        if let onOpenDocument {
            Button(action: onOpenDocument) {
                row
            }
            .buttonStyle(.plain)
            .accessibilityHint("Mở tài liệu gốc".localized(for: appLanguage))
        } else {
            row
        }
    }

    /// A full-width row rather than a fixed 280pt card in a sideways scroller, which left every
    /// source after the first behind a swipe with nothing on screen to suggest it.
    private var row: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "book.closed.fill")
                .appFont(size: 15)
                .foregroundColor(ChatPalette.accentText)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(source.title)
                    .appFont(size: 16, weight: .semibold, design: .rounded)
                    .foregroundColor(Color(.label))

                Text(verbatim: "\(source.documentName) · \(String(format: "Tr. %lld".localized(for: appLanguage), source.page))")
                    .appFont(size: 14, design: .rounded)
                    .foregroundColor(ChatPalette.secondaryText)
            }

            Spacer(minLength: 8)

            if onOpenDocument != nil {
                Image(systemName: "chevron.right")
                    .appFont(size: 14, weight: .semibold)
                    .foregroundColor(Color(.tertiaryLabel))
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 8)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Citations Stack

struct CitationsView: View {
    let sources: [MedicalSource]
    /// Whether a source's PDF is bundled — decides if its row opens a document preview.
    var hasDocument: (MedicalSource) -> Bool = { _ in false }
    var onOpenDocument: (MedicalSource) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Nguồn tài liệu")
                .appFont(size: 14, weight: .semibold, design: .rounded)
                .foregroundColor(ChatPalette.secondaryText)
                .accessibilityAddTraits(.isHeader)

            ForEach(sources) { source in
                CitationCard(
                    source: source,
                    onOpenDocument: hasDocument(source) ? { onOpenDocument(source) } : nil
                )
            }
        }
    }
}

#Preview {
    CitationsView(sources: [
        MedicalSource(
            id: "1",
            title: "Hướng dẫn chăm sóc sau phẫu thuật đại trực tràng",
            excerpt: "Các dấu hiệu nhiễm trùng vết mổ cần được theo dõi hàng ngày...",
            page: 12,
            documentName: "Post-Surgery Care Protocol 2024"
        ),
        MedicalSource(
            id: "2",
            title: "Quản lý đau sau phẫu thuật",
            excerpt: "Đau ở mức độ vừa phải là bình thường trong 3-5 ngày đầu...",
            page: 8,
            documentName: "Pain Management Guidelines"
        )
    ], hasDocument: { $0.id == "1" })
    .padding()
}
