//
//  CitattionCard.swift
//  MobiCureVN
//
//  Created by Anh Phung on 4/24/26.
//

import SwiftUI

struct CitationCard: View {

    let source: MedicalSource
    @State private var isExpanded = false

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                isExpanded.toggle()
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                // Header row
                HStack(spacing: 8) {
                    Image(systemName: "doc.text.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.accentColor)

                    Text(source.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color(.label))
                        .lineLimit(isExpanded ? nil : 1)

                    Spacer()

                    Text("Tr. \(source.page)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(Color.accentColor.opacity(0.12))
                        )

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color(.secondaryLabel))
                }

                // Excerpt (expanded only)
                if isExpanded {
                    Text(source.excerpt)
                        .font(.system(size: 13))
                        .foregroundColor(Color(.secondaryLabel))
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity.combined(with: .move(edge: .top)))

                    Text(source.documentName)
                        .font(.system(size: 11, weight: .medium))
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
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Citations Stack

struct CitationsView: View {
    let sources: [MedicalSource]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Nguồn tài liệu", systemImage: "books.vertical.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Color(.secondaryLabel))
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(sources) { source in
                        CitationCard(source: source)
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
