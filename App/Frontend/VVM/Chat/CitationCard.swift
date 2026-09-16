//
//  CitationCard.swift
//  MobiCureVN
//
//  Created by Anh Phung on 4/24/26.
//

import SwiftUI

struct CitationCard: View {

    let source: MedicalSource
    /// Opens the source PDF; nil when the document isn't bundled, in which case tapping the
    /// card expands the excerpt instead.
    var onOpenDocument: (() -> Void)? = nil
    @State private var isExpanded = false

    @AppStorage(AppLanguage.storageKey) private var appLanguageRaw = AppLanguage.vietnamese.rawValue
    private var appLanguage: AppLanguage { AppLanguage(rawValue: appLanguageRaw) ?? .vietnamese }

    private let chevronSize: CGFloat = 24

    var body: some View {
        // The expand chevron is its own button laid over the card rather than nested inside
        // the card's button, so the two taps stay independent (and separately reachable by
        // VoiceOver).
        ZStack(alignment: .topTrailing) {
            Button {
                if let onOpenDocument {
                    onOpenDocument()
                } else {
                    toggleExpanded()
                }
            } label: {
                cardContent
            }
            .buttonStyle(.plain)
            .accessibilityHint(onOpenDocument == nil ? "" : "Mở tài liệu gốc".localized(for: appLanguage))

            Button(action: toggleExpanded) {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .appFont(size: 11, weight: .semibold)
                    .foregroundColor(Color(.secondaryLabel))
                    .frame(width: chevronSize, height: chevronSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
            .padding(.trailing, 8)
            .accessibilityLabel((isExpanded ? "Ẩn đoạn trích" : "Xem đoạn trích").localized(for: appLanguage))
        }
    }

    private func toggleExpanded() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            isExpanded.toggle()
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header row
            HStack(spacing: 8) {
                Image(systemName: onOpenDocument == nil ? "doc.text.fill" : "doc.richtext.fill")
                    .appFont(size: 12)
                    .foregroundColor(.accentColor)

                Text(source.title)
                    .appFont(size: 13, weight: .semibold)
                    .foregroundColor(Color(.label))
                    .lineLimit(isExpanded ? nil : 1)

                Spacer()

                Text(String(format: "Tr. %lld".localized(for: appLanguage), source.page))
                    .appFont(size: 11, weight: .medium)
                    .foregroundColor(.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(Color.accentColor.opacity(0.12))
                    )

                // Reserves the space the overlaid chevron button occupies.
                Color.clear
                    .frame(width: chevronSize - 4, height: 1)
            }

            // Excerpt (expanded only)
            if isExpanded {
                Text(source.excerpt)
                    .appFont(size: 13)
                    .foregroundColor(Color(.secondaryLabel))
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity.combined(with: .move(edge: .top)))

                Text(source.documentName)
                    .appFont(size: 11, weight: .medium)
                    .foregroundColor(Color(.tertiaryLabel))
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.2), lineWidth: 1)
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Citations Stack

struct CitationsView: View {
    let sources: [MedicalSource]
    /// Whether a source's PDF is bundled — decides if its card opens a document preview.
    var hasDocument: (MedicalSource) -> Bool = { _ in false }
    var onOpenDocument: (MedicalSource) -> Void = { _ in }

    @AppStorage(AppLanguage.storageKey) private var appLanguageRaw = AppLanguage.vietnamese.rawValue
    private var appLanguage: AppLanguage { AppLanguage(rawValue: appLanguageRaw) ?? .vietnamese }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Nguồn tài liệu".localized(for: appLanguage), systemImage: "books.vertical.fill")
                .appFont(size: 12, weight: .semibold)
                .foregroundColor(Color(.secondaryLabel))
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(sources) { source in
                        CitationCard(
                            source: source,
                            onOpenDocument: hasDocument(source) ? { onOpenDocument(source) } : nil
                        )
                            .frame(width: 280)
                    }
                }
                .padding(.horizontal, 16)
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
    ])
    .padding(.vertical)
}
