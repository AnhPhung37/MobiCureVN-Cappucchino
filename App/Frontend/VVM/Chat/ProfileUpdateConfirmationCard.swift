import SwiftUI

/// A single proposed profile change with Accept/Dismiss actions. Shared between the inline
/// chat confirmation card (`ProfileUpdateConfirmationCard`, below) and the Profile tab's
/// pending-updates list (`ProfileView`) so the two surfaces stay visually and behaviorally
/// identical.
///
/// High-stakes proposals (diagnosis/procedure/recovery stage) get distinct amber styling and
/// an extra native confirmation dialog on Accept — a second speed bump beyond the general
/// confirm-before-write gate, since a wrong edit to a clinical field is far costlier than a
/// wrong care note.
struct ProfileUpdateRow: View {
    let update: ProposedProfileUpdate
    let onAccept: (ProposedProfileUpdate) -> Void
    let onDismiss: (ProposedProfileUpdate) -> Void

    @State private var isConfirmingHighStakesAccept = false

    @AppStorage(AppLanguage.storageKey) private var appLanguageRaw = AppLanguage.vietnamese.rawValue
    private var appLanguage: AppLanguage { AppLanguage(rawValue: appLanguageRaw) ?? .vietnamese }
    private func t(_ key: String) -> String { key.localized(for: appLanguage) }

    private var accentColor: Color { update.isHighStakes ? .orange : .cyan }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: update.isHighStakes ? "exclamationmark.triangle.fill" : "sparkles")
                .font(.system(size: 12))
                .foregroundColor(accentColor)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(update.field.displayLabel)
                        .font(.system(size: 13, weight: .semibold))
                    if update.isHighStakes {
                        Text(t("Trường lâm sàng"))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.orange.opacity(0.15)))
                    }
                }

                if let previous = update.previousValue {
                    Text("\(previous) → \(update.newValue)")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(Color(.label))
                } else {
                    Text(update.newValue)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(Color(.label))
                }

                if update.isHighStakes {
                    Text(t("Chỉ xác nhận nếu điều này chính xác — mục này cập nhật hồ sơ lâm sàng của bạn."))
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                }

                if update.status == .pending {
                    HStack(spacing: 10) {
                        Button {
                            if update.isHighStakes {
                                isConfirmingHighStakesAccept = true
                            } else {
                                onAccept(update)
                            }
                        } label: {
                            Text(t("Xác nhận"))
                                .font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(accentColor))
                                .foregroundColor(.white)
                        }
                        .buttonStyle(.plain)

                        Button {
                            onDismiss(update)
                        } label: {
                            Text(t("Bỏ qua"))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(Color(.secondaryLabel))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(Color(.tertiarySystemBackground)))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 2)
                } else {
                    Text(update.status == .accepted ? t("Đã xác nhận") : t("Đã bỏ qua"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(update.status == .accepted ? .cyan : Color(.tertiaryLabel))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.systemBackground))
        )
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
            Text(String(format: t("Thao tác này sẽ cập nhật %@ trong hồ sơ của bạn. Chỉ xác nhận nếu chính xác."), update.field.displayLabel))
        }
    }
}

/// Inline chat-turn card listing the still-pending proposals surfaced by that turn. Hides
/// itself once every proposal on the message has been resolved.
struct ProfileUpdateConfirmationCard: View {
    let updates: [ProposedProfileUpdate]
    let onAccept: (ProposedProfileUpdate) -> Void
    let onDismiss: (ProposedProfileUpdate) -> Void

    @AppStorage(AppLanguage.storageKey) private var appLanguageRaw = AppLanguage.vietnamese.rawValue
    private var appLanguage: AppLanguage { AppLanguage(rawValue: appLanguageRaw) ?? .vietnamese }
    private func t(_ key: String) -> String { key.localized(for: appLanguage) }

    var body: some View {
        let pending = updates.filter { $0.status == .pending }
        if !pending.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label(t("Cập nhật hồ sơ?"), systemImage: "wand.and.stars")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(.secondaryLabel))
                    .padding(.horizontal, 16)

                VStack(spacing: 8) {
                    ForEach(pending) { update in
                        ProfileUpdateRow(update: update, onAccept: onAccept, onDismiss: onDismiss)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }
}
