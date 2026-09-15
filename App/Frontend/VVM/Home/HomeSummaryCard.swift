import SwiftUI

/// Shared chrome for every card on the Home dashboard, so the five cards cannot drift apart in
/// corner radius, padding or header weight the way the old mockup's cards had (one had a
/// shadow, its neighbour did not).
///
/// The "see all" footer is part of the card rather than the content, because Home only ever
/// summarises: a card that truncates must always offer the way to the full list, and making
/// that structural stops a future card from quietly dropping it.
struct HomeSummaryCard<Content: View>: View {
    let icon: String
    var iconColor: Color = .accentColor
    /// Vietnamese source string; resolved through the environment locale by `Text`.
    let title: LocalizedStringKey
    /// Uncapped total. Shown as a badge so a truncated card still says how much it is hiding.
    var count: Int?
    var seeAllLabel: LocalizedStringKey = "Xem tất cả"
    var onSeeAll: (() -> Void)?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            content()
            if let onSeeAll {
                Button(action: onSeeAll) {
                    HStack(spacing: 4) {
                        Text(seeAllLabel)
                        Image(systemName: "chevron.right")
                            .appFont(size: 12, weight: .semibold)
                    }
                    .appFont(size: 14, weight: .semibold)
                    .foregroundColor(.accentColor)
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .appFont(size: 16, weight: .semibold)
                .foregroundColor(iconColor)
            Text(title)
                .appFont(size: 17, weight: .semibold)
                .foregroundColor(Color(.label))
            Spacer(minLength: 0)
            if let count, count > 0 {
                Text("\(count)")
                    .appFont(size: 13, weight: .semibold)
                    .foregroundColor(iconColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(iconColor.opacity(0.15)))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A short list of plain strings — care notes and warning signs. Items are rendered in the
/// order they were stored and are never re-sorted; ranking them would be a clinical judgement
/// the app is not allowed to make.
struct HomeBulletList: View {
    let items: [String]
    var bullet: String = "circle.fill"
    var bulletColor: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: bullet)
                        .appFont(size: 7)
                        .foregroundColor(bulletColor)
                    Text(item)
                        .appFont(size: 15)
                        .foregroundColor(Color(.label))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

/// Shown instead of content when a card has nothing to display. Always explains *how* the card
/// fills up, so an empty Home reads as "nothing yet" rather than "broken".
struct HomeEmptyState: View {
    let message: LocalizedStringKey

    var body: some View {
        Text(message)
            .appFont(size: 14)
            .foregroundColor(Color(.secondaryLabel))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.systemBackground))
            )
    }
}
