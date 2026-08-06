import SwiftUI
import UIKit

struct ProfileView: View {
    @State var viewModel: ProfileViewModel
    /// Present-as-sheet convenience: shown when Profile is a sheet so it has its own dismiss
    /// affordance. Harmless when pushed instead.
    @Environment(\.dismiss) private var dismiss

    /// The UI language chosen with the VI/EN picker. Read here directly so the sheet localizes
    /// correctly regardless of whether it inherits the presenter's `\.locale` environment, and
    /// so it live-updates when the user flips the toggle while Profile is open.
    @AppStorage(AppLanguage.storageKey) private var appLanguageRaw = AppLanguage.vietnamese.rawValue
    private var appLanguage: AppLanguage { AppLanguage(rawValue: appLanguageRaw) ?? .vietnamese }

    /// Resolve a catalog key in the chosen UI language. Keys are the Vietnamese source strings,
    /// matching the rest of the app's `Localizable.xcstrings` convention.
    private func t(_ key: String) -> String { key.localized(for: appLanguage) }

    init(viewModel: ProfileViewModel = ProfileViewModel(repository: MockProfileRepository())) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if viewModel.isLoading {
                        ProgressView(t("Đang tải hồ sơ..."))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    } else if let profile = viewModel.profile {
                        headerCard(profile)
                        profileDetails(profile)
                        notesCard(title: "Care notes", items: profile.careNotes, icon: "checkmark.circle.fill")
                        notesCard(title: "Warning signs", items: profile.warningSigns, icon: "exclamationmark.triangle.fill")
                        rememberedFactsCard
                        pendingUpdatesCard
                        highStakesHistoryCard
                        woundPhotosCard
                        sourceCard(profile)
                    } else if let error = viewModel.errorMessage {
                        Text(error)
                            .foregroundColor(.red)
                            .padding()
                    } else {
                        ContentUnavailableView(t("Không có hồ sơ"), systemImage: "person.crop.circle.badge.questionmark", description: Text(t("Chưa tải được hồ sơ.")))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
            .background(
                LinearGradient(
                    colors: [Color(.systemBackground), Color.cyan.opacity(0.08)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            )
            .navigationTitle(t("Hồ sơ"))
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundColor(Color(.tertiaryLabel))
                    }
                    .accessibilityLabel(t("Đóng"))
                }
            }
            .task {
                await viewModel.load()
            }
        }
        // Also propagate the chosen language to any SwiftUI Text/LocalizedStringKey inside
        // (e.g. notesCard titles) so they resolve consistently with the explicit t(...) calls.
        .environment(\.locale, appLanguage.locale)
    }

    private func headerCard(_ profile: PatientProfile) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.cyan.opacity(0.15))
                    .frame(width: 64, height: 64)
                Text(String(profile.name.prefix(1)))
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.cyan)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(profile.name)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text(profile.diagnosis)
                    .font(.system(size: 14))
                    .foregroundColor(Color(.secondaryLabel))
                    .lineLimit(2)
                Text(profile.recoveryStage)
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.cyan.opacity(0.15)))
                    .foregroundColor(.cyan)
            }

            Spacer()
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private func profileDetails(_ profile: PatientProfile) -> some View {
        VStack(spacing: 12) {
            detailRow(label: t("Age"), value: "\(profile.age)")
            detailRow(label: t("Gender"), value: profile.gender)
            detailRow(label: t("Procedure"), value: profile.procedure)
            detailRow(label: t("Last updated"), value: Self.dateFormatter.string(from: profile.lastUpdated))
            VStack(alignment: .leading, spacing: 8) {
                Text(t("Report summary"))
                    .font(.headline)
                Text(profile.reportSummary)
                    .font(.system(size: 14))
                    .foregroundColor(Color(.secondaryLabel))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(.systemBackground))
            )
        }
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundColor(Color(.secondaryLabel))
            Spacer()
            Text(value)
                .fontWeight(.semibold)
                .multilineTextAlignment(.trailing)
        }
        .font(.system(size: 14))
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.systemBackground))
        )
    }

    private func notesCard(title: String, items: [String], icon: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundColor(.cyan)
                Text(t(title))
                    .font(.headline)
            }

            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(Color.cyan.opacity(0.4))
                        .frame(width: 7, height: 7)
                        .padding(.top, 6)
                    Text(item)
                        .font(.system(size: 14))
                        .foregroundColor(Color(.label))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    // MARK: - Remembered Facts ("system prompt")

    /// The facts the AI has gathered this conversation — presented as "what the assistant knows
    /// about you", which is exactly the block injected into the live system prompt.
    private var rememberedFactsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundColor(.cyan)
                Text(t("Trợ lý ghi nhớ về bạn"))
                    .font(.headline)
                Spacer()
            }

            Text(t("Những thông tin bạn đã chia sẻ trong cuộc trò chuyện này. Trợ lý dùng chúng để trả lời phù hợp hơn."))
                .font(.system(size: 12))
                .foregroundColor(Color(.secondaryLabel))
                .fixedSize(horizontal: false, vertical: true)

            if viewModel.hasRememberedFacts {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(viewModel.rememberedFacts.enumerated()), id: \.offset) { _, fact in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(fact.label):")
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                .foregroundColor(.cyan)
                            Text(fact.value)
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundColor(Color(.label))
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(.systemBackground))
                )
            } else {
                Text(t("Chưa có thông tin nào được ghi nhớ. Hãy chia sẻ về tình trạng của bạn trong khi trò chuyện."))
                    .font(.system(size: 13))
                    .foregroundColor(Color(.secondaryLabel))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(.systemBackground))
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    // MARK: - Pending Profile Updates
    //
    // AI-proposed updates from chat, awaiting confirmation. The durable fallback surface — a
    // proposal shown here even if the patient never acted on the inline chat card, since this
    // reads straight from AppConfig.profileUpdateStore rather than the current conversation.

    @ViewBuilder
    private var pendingUpdatesCard: some View {
        if !viewModel.pendingUpdates.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "wand.and.stars")
                        .foregroundColor(.cyan)
                    Text(t("Đề xuất cập nhật hồ sơ"))
                        .font(.headline)
                    Spacer()
                    Text("\(viewModel.pendingUpdates.count)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.cyan)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.cyan.opacity(0.15)))
                }

                Text(t("Trợ lý nhận thấy những thông tin này từ cuộc trò chuyện. Xác nhận để cập nhật hồ sơ của bạn."))
                    .font(.system(size: 12))
                    .foregroundColor(Color(.secondaryLabel))
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 8) {
                    ForEach(viewModel.pendingUpdates) { update in
                        ProfileUpdateRow(
                            update: update,
                            onAccept: { Task { await viewModel.accept($0) } },
                            onDismiss: { Task { await viewModel.dismiss($0) } }
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
        }
    }

    // MARK: - Clinical Change History
    //
    // Audit trail for high-stakes fields (diagnosis/procedure/recovery stage): every resolved
    // proposal, so a bad edit can be caught after the fact even though nothing after Accept
    // requires a clinician's sign-off.

    @ViewBuilder
    private var highStakesHistoryCard: some View {
        if !viewModel.highStakesHistory.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundColor(.orange)
                    Text(t("Lịch sử thay đổi lâm sàng"))
                        .font(.headline)
                }

                VStack(spacing: 8) {
                    ForEach(viewModel.highStakesHistory) { update in
                        highStakesHistoryRow(update)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
        }
    }

    private func highStakesHistoryRow(_ update: ProposedProfileUpdate) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(update.field.displayLabel)
                    .font(.system(size: 13, weight: .semibold))
                Text(update.status == .accepted ? t("Đã xác nhận") : t("Đã bỏ qua"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(update.status == .accepted ? .cyan : Color(.tertiaryLabel))
                Spacer()
                Text(Self.dateFormatter.string(from: update.createdAt))
                    .font(.system(size: 11))
                    .foregroundColor(Color(.secondaryLabel))
            }
            if let previous = update.previousValue {
                Text("\(previous) → \(update.newValue)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Color(.secondaryLabel))
            } else {
                Text(update.newValue)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Color(.secondaryLabel))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.systemBackground))
        )
    }

    // MARK: - Uploaded Wound Photos

    private var woundPhotosCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "photo.on.rectangle.angled")
                    .foregroundColor(.cyan)
                Text(t("Ảnh vết thương đã tải lên"))
                    .font(.headline)
                Spacer()
                if !viewModel.woundEntries.isEmpty {
                    Text("\(viewModel.woundEntries.count)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.cyan)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.cyan.opacity(0.15)))
                }
            }

            if viewModel.woundEntries.isEmpty {
                Text(t("Chưa có ảnh nào. Dùng nút “Phân tích vết thương” trong màn hình trò chuyện để thêm."))
                    .font(.system(size: 13))
                    .foregroundColor(Color(.secondaryLabel))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(.systemBackground))
                    )
            } else {
                VStack(spacing: 10) {
                    ForEach(viewModel.woundEntries) { entry in
                        woundEntryRow(entry)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private func woundEntryRow(_ entry: WoundLogEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            woundThumbnail(entry.imageReference)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(Self.dateFormatter.string(from: entry.capturedAt))
                        .font(.system(size: 13, weight: .semibold))
                    if entry.flaggedForReview {
                        HStack(spacing: 3) {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text(t("Cần theo dõi"))
                        }
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.orange)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.orange.opacity(0.15)))
                    }
                }

                woundDetail(t("Màu stoma"), entry.stomaColor)
                woundDetail(t("Da xung quanh"), entry.surroundingSkin)
                woundDetail(t("Sưng / lồi"), entry.swellingOrProtrusion)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.systemBackground))
        )
    }

    @ViewBuilder
    private func woundDetail(_ label: String, _ value: String) -> some View {
        // Hide fields the model didn't report to keep rows compact.
        if value != WoundFindingsParser.notReported {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(label):")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(.secondaryLabel))
                Text(value)
                    .font(.system(size: 12))
                    .foregroundColor(Color(.label))
                    .lineLimit(2)
            }
        }
    }

    /// Loads a wound photo from its file URL. `UIImage(contentsOfFile:)` reads the JPEG saved by
    /// `WoundPhotoStore`; a missing file (e.g. entry outlived its photo) falls back to a
    /// placeholder rather than crashing.
    private func woundThumbnail(_ url: URL) -> some View {
        Group {
            if let uiImage = UIImage(contentsOfFile: url.path) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color(.tertiarySystemBackground)
                    Image(systemName: "photo")
                        .foregroundColor(Color(.tertiaryLabel))
                }
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func sourceCard(_ profile: PatientProfile) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(t("Data source"))
                    .font(.headline)
                Text(profile.sourceName)
                    .font(.system(size: 14))
                    .foregroundColor(Color(.secondaryLabel))
            }
            Spacer()
            Image(systemName: "doc.text.magnifyingglass")
                .foregroundColor(.cyan)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.systemBackground))
        )
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

#Preview {
    ProfileView(viewModel: ProfileViewModel(repository: MockProfileRepository()))
}
