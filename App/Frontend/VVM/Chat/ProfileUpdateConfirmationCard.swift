import SwiftUI

/// How a `ProfileUpdateRow` is presented. The two surfaces that show proposals want the same
/// content and the same behaviour but read very differently: in chat the row is part of the
/// assistant's message and must not look like a separate widget dropped underneath it, while on
/// the Profile screen it is a standalone item in a list of its own.
enum ProfileUpdateRowStyle {
    /// Inside the assistant's chat bubble — transparent, tighter, smaller type, so the offer
    /// reads as the tail end of what the assistant just said.
    case inline
    /// Standalone card on the Profile screen.
    case card

    var isInline: Bool { self == .inline }
}

/// A single proposed profile change with Confirm/Ignore actions. Shared between the inline chat
/// confirmation block (`ProfileUpdateConfirmationCard`, below) and the Profile tab's
/// pending-updates list (`ProfileView`) so the two surfaces stay behaviourally identical.
///
/// High-stakes proposals (diagnosis/procedure/recovery stage) get distinct amber styling and
/// an extra native confirmation dialog on Confirm — a second speed bump beyond the general
/// confirm-before-write gate, since a wrong edit to a clinical field is far costlier than a
/// wrong care note.
struct ProfileUpdateRow: View {
    let update: ProposedProfileUpdate
    var style: ProfileUpdateRowStyle = .card
    let onAccept: (ProposedProfileUpdate) -> Void
    let onDismiss: (ProposedProfileUpdate) -> Void

    @State private var isConfirmingHighStakesAccept = false

    @AppStorage(AppLanguage.storageKey) private var appLanguageRaw = AppLanguage.vietnamese.rawValue
    private var appLanguage: AppLanguage { AppLanguage(rawValue: appLanguageRaw) ?? .vietnamese }
    private func t(_ key: String) -> String { key.localized(for: appLanguage) }

    private var accentColor: Color { update.isHighStakes ? .orange : .cyan }
    private var isPending: Bool { update.status == .pending }

    var body: some View {
        Group {
            if isPending {
                pendingRow
            } else {
                resolvedRow
            }
        }
        .padding(style.isInline ? 0 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .confirmationDialog(
            t("Xác nhận thay đổi hồ sơ lâm sàng?"),
            isPresented: $isConfirmingHighStakesAccept,
            titleVisibility: .visible
        ) {
            Button(t("Xác nhận")) { onAccept(update) }
            Button(t("Huỷ"), role: .cancel) {}
        } message: {
            // %@ substituted after localization lookup (not interpolated into the key first),
            // matching the "Tr. %lld" pattern in CitationCard.swift — so a future English
            // catalog entry for this template still matches correctly.
            Text(String(format: t("Thao tác này sẽ cập nhật %@ trong hồ sơ của bạn. Chỉ xác nhận nếu chính xác."), t(update.field.displayLabel)))
        }
    }

    // MARK: - States

    private var pendingRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: update.isHighStakes ? "exclamationmark.triangle.fill" : "sparkles")
                .font(.system(size: style.isInline ? 11 : 12))
                .foregroundColor(accentColor)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(t(update.field.displayLabel))
                        .font(.system(size: style.isInline ? 12 : 13, weight: .semibold))
                        .foregroundColor(Color(.secondaryLabel))
                    if update.isHighStakes {
                        Text(t("Trường lâm sàng"))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.orange.opacity(0.15)))
                    }
                }

                valueText

                if update.isHighStakes {
                    Text(t("Chỉ xác nhận nếu điều này chính xác — mục này cập nhật hồ sơ lâm sàng của bạn."))
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                actionButtons
            }
            Spacer(minLength: 0)
        }
    }

    /// Kept in place after a decision rather than disappearing: the patient should be able to
    /// see what they just agreed to (or waved off) without leaving the conversation, and a card
    /// that vanishes on tap gives no confirmation that anything happened.
    private var resolvedRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: update.status == .accepted ? "checkmark.circle.fill" : "slash.circle")
                .font(.system(size: 11))
                .foregroundColor(update.status == .accepted ? .cyan : Color(.tertiaryLabel))

            Text(update.status == .accepted
                 ? String(format: t("Đã lưu %@ vào hồ sơ"), t(update.field.displayLabel))
                 : String(format: t("Đã bỏ qua %@"), t(update.field.displayLabel)))
                .font(.system(size: style.isInline ? 12 : 13))
                .foregroundColor(Color(.secondaryLabel))
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
    }

    // MARK: - Pieces

    @ViewBuilder
    private var valueText: some View {
        if let previous = update.previousValue {
            // The arrow carries the meaning here, so the two values are shown together rather
            // than as a bare new value that hides what it is replacing.
            HStack(spacing: 6) {
                Text(previous)
                    .strikethrough(color: Color(.tertiaryLabel))
                    .foregroundColor(Color(.tertiaryLabel))
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Color(.tertiaryLabel))
                Text(update.newValue)
                    .foregroundColor(Color(.label))
            }
            .font(.system(size: style.isInline ? 14 : 13, weight: .medium, design: .rounded))
            .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(update.newValue)
                .font(.system(size: style.isInline ? 14 : 13, weight: .medium, design: .rounded))
                .foregroundColor(Color(.label))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            Button {
                if update.isHighStakes {
                    isConfirmingHighStakesAccept = true
                } else {
                    onAccept(update)
                }
            } label: {
                Label(t("Lưu"), systemImage: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(accentColor))
                    .foregroundColor(.white)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(format: t("Lưu %@ vào hồ sơ"), t(update.field.displayLabel)))

            Button {
                onDismiss(update)
            } label: {
                Text(t("Bỏ qua"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(.secondaryLabel))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color(.tertiarySystemFill)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(format: t("Bỏ qua %@"), t(update.field.displayLabel)))
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private var rowBackground: some View {
        if style.isInline {
            // Transparent: the row sits on the assistant bubble's own fill.
            Color.clear
        } else {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.systemBackground))
        }
    }
}

/// The proposals surfaced by one assistant turn, rendered *inside* that turn's bubble.
///
/// This is deliberately not a floating card below the message: a profile update is something
/// the assistant noticed while answering, so it reads as the tail of its own reply — a hairline
/// rule, a quiet one-line prompt, then the fields. Resolved proposals stay put (greyed, with
/// what was decided) instead of vanishing, so the transcript records the decision.
struct ProfileUpdateConfirmationCard: View {
    let updates: [ProposedProfileUpdate]
    let onAccept: (ProposedProfileUpdate) -> Void
    let onDismiss: (ProposedProfileUpdate) -> Void

    @AppStorage(AppLanguage.storageKey) private var appLanguageRaw = AppLanguage.vietnamese.rawValue
    private var appLanguage: AppLanguage { AppLanguage(rawValue: appLanguageRaw) ?? .vietnamese }
    private func t(_ key: String) -> String { key.localized(for: appLanguage) }

    private var hasPending: Bool { updates.contains { $0.status == .pending } }

    var body: some View {
        if !updates.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Divider()
                    .padding(.top, 2)

                if hasPending {
                    HStack(spacing: 6) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 11))
                        Text(t("Mình có nên nhớ điều này không?"))
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundColor(Color(.secondaryLabel))
                }

                VStack(alignment: .leading, spacing: 12) {
                    ForEach(updates) { update in
                        ProfileUpdateRow(
                            update: update,
                            style: .inline,
                            onAccept: onAccept,
                            onDismiss: onDismiss
                        )
                    }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: updates)
        }
    }
}
