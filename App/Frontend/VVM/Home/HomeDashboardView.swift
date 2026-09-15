import SwiftUI

/// The patient's overview (#54), reached from the chat header. It replaced a mockup whose
/// greeting ("Chào Nam,"), streak ("256 days STRONG") and appointment ("Dr. Schmitz,
/// 11:30 - 12:00") were all invented, and whose menu and "Xem phân tích" buttons did nothing.
///
/// Chat is the app's main screen, so this is presented as a sheet over it: the patient checks
/// something here and returns to the conversation exactly where they left it.
///
/// Every card here reads from a repository or shows an empty state that explains how it fills
/// up. Nothing is placeholder content: on a recovery screen a plausible-looking fake reads as
/// fact, which is a patient-safety problem rather than a cosmetic one.
///
/// Home *summarises*. `ProfileView` owns the full lists and all editing, and each card's
/// "Xem tất cả" opens it scrolled to the matching section.
struct HomeDashboardView: View {
    @State private var viewModel: HomeViewModel
    @State private var profileSection: ProfileView.Section?
    @State private var isShowingGallery = false
    @State private var isShowingRememberedFacts = false

    @Environment(\.dismiss) private var dismiss

    @AppStorage(AppLanguage.storageKey) private var appLanguageRaw = AppLanguage.vietnamese.rawValue
    private var appLanguage: AppLanguage { AppLanguage(rawValue: appLanguageRaw) ?? .vietnamese }
    private func t(_ key: String) -> String { key.localized(for: appLanguage) }

    init(viewModel: HomeViewModel = HomeViewModel()) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    greetingCard
                    careNotesCard
                    warningSignsCard
                    rememberedCard
                    woundPhotosCard
                    dataSourceCard
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .navigationTitle("Trang chủ")
            .navigationBarTitleDisplayMode(.large)
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
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        profileSection = .top
                    } label: {
                        Image(systemName: "person.crop.circle")
                            .appFont(size: 22)
                            .foregroundColor(.accentColor)
                    }
                    .accessibilityLabel(t("Hồ sơ"))
                }
            }
            .navigationDestination(isPresented: $isShowingGallery) {
                WoundGalleryView(entries: viewModel.allWoundEntries)
            }
            .navigationDestination(isPresented: $isShowingRememberedFacts) {
                RememberedFactsView(facts: viewModel.allRememberedFacts)
            }
            .sheet(item: $profileSection) { section in
                ProfileView(
                    viewModel: ProfileViewModel(repository: AppConfig.profileRepository),
                    scrollTo: section
                )
            }
            .task {
                await viewModel.load()
            }
            // A profile edit changes what these cards should say, so re-read on dismissal.
            .onChange(of: profileSection) { _, section in
                if section == nil { Task { await viewModel.load() } }
            }
        }
        // Propagate the chosen language the way ProfileView does, so a sheet that may not
        // inherit the presenter's locale still resolves its Text literals correctly.
        .environment(\.locale, appLanguage.locale)
    }

    // MARK: - Greeting

    /// Carries no status judgement — no recovery score, no streak, no "you are doing well".
    /// The app is an assistant and has not assessed the patient; a greeting that implied
    /// otherwise would be claiming clinical authority it does not have.
    private var greetingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(greetingText)
                .appFont(size: 26, weight: .bold, design: .rounded)
                .foregroundColor(Color(.label))
                .fixedSize(horizontal: false, vertical: true)

            Text("Đây là những gì trợ lý biết về quá trình hồi phục của bạn.")
                .appFont(size: 15)
                .foregroundColor(Color(.secondaryLabel))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    /// Falls back to an unnamed greeting rather than inventing one. The old mockup hardcoded
    /// "Chào Nam," for every patient.
    private var greetingText: String {
        let name = viewModel.profile?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { return t("Chào bạn,") }
        return String(format: t("Chào %@,"), name)
    }

    // MARK: - Care notes

    private var careNotesCard: some View {
        HomeSummaryCard(
            icon: "checkmark.circle.fill",
            iconColor: .green,
            title: "Lưu ý chăm sóc",
            count: viewModel.careNotesTotalCount,
            onSeeAll: viewModel.hasMoreCareNotes ? { profileSection = .careNotes } : nil
        ) {
            if viewModel.careNotesSummary.isEmpty {
                HomeEmptyState(message: "Chưa có lưu ý chăm sóc nào. Lưu ý sẽ xuất hiện khi hồ sơ của bạn có thông tin từ báo cáo y tế.")
            } else {
                HomeBulletList(items: viewModel.careNotesSummary, bulletColor: .green)
            }
        }
    }

    // MARK: - Warning signs

    /// Listed in stored order, never ranked. Styled as a caution, not an active alarm: a
    /// persistent red alert on the home screen would read as "something is wrong right now".
    private var warningSignsCard: some View {
        HomeSummaryCard(
            icon: "exclamationmark.triangle.fill",
            iconColor: .orange,
            title: "Dấu hiệu cảnh báo",
            count: viewModel.warningSignsTotalCount,
            onSeeAll: viewModel.hasMoreWarningSigns ? { profileSection = .warningSigns } : nil
        ) {
            if viewModel.warningSignsSummary.isEmpty {
                HomeEmptyState(message: "Chưa có dấu hiệu cảnh báo nào trong hồ sơ của bạn.")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HomeBulletList(items: viewModel.warningSignsSummary, bulletColor: .orange)
                    Text("Nếu bạn gặp bất kỳ dấu hiệu nào, hãy liên hệ nhân viên y tế.")
                        .appFont(size: 13)
                        .foregroundColor(Color(.secondaryLabel))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Remembered facts

    private var rememberedCard: some View {
        HomeSummaryCard(
            icon: "brain.head.profile",
            iconColor: .accentColor,
            title: "Trợ lý ghi nhớ về bạn",
            count: viewModel.rememberedFactsTotalCount,
            onSeeAll: viewModel.hasMoreRememberedFacts ? { isShowingRememberedFacts = true } : nil
        ) {
            if viewModel.rememberedFacts.isEmpty {
                HomeEmptyState(message: "Trợ lý chưa ghi nhớ điều gì. Khi bạn kể một chi tiết trong lúc trò chuyện và xác nhận, nó sẽ xuất hiện ở đây.")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(viewModel.rememberedFacts) { fact in
                        rememberedRow(fact)
                    }
                }
            }
        }
    }

    private func rememberedRow(_ fact: HomeViewModel.RememberedFact) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(fact.value)
                .appFont(size: 15, weight: .medium)
                .foregroundColor(Color(.label))
                .fixedSize(horizontal: false, vertical: true)
            Text("\(t(fact.label)) · \(Self.dateFormatter.string(from: fact.recordedAt))")
                .appFont(size: 12)
                .foregroundColor(Color(.secondaryLabel))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.systemBackground))
        )
        .accessibilityElement(children: .combine)
    }

    // MARK: - Wound photos

    private var woundPhotosCard: some View {
        HomeSummaryCard(
            icon: "photo.on.rectangle.angled",
            iconColor: .accentColor,
            title: "Ảnh vết thương",
            count: viewModel.woundEntriesTotalCount,
            onSeeAll: viewModel.allWoundEntries.isEmpty ? nil : { isShowingGallery = true }
        ) {
            if viewModel.recentWoundEntries.isEmpty {
                HomeEmptyState(message: "Chưa có ảnh nào. Đính kèm ảnh trong màn hình trò chuyện để trợ lý ghi lại.")
            } else {
                HStack(spacing: 10) {
                    ForEach(viewModel.recentWoundEntries) { entry in
                        WoundThumbnail(url: entry.imageReference, size: 68)
                            .overlay(alignment: .topTrailing) {
                                if entry.flaggedForReview {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .appFont(size: 11)
                                        .foregroundColor(.orange)
                                        .padding(3)
                                        .background(Circle().fill(Color(.systemBackground)))
                                        .padding(3)
                                }
                            }
                            .accessibilityLabel(thumbnailLabel(for: entry))
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// Wound photos look alike; the date is what tells them apart for a VoiceOver user, and the
    /// follow-up flag has to be spoken rather than only shown as a coloured badge.
    private func thumbnailLabel(for entry: WoundLogEntry) -> String {
        let date = Self.dateFormatter.string(from: entry.capturedAt)
        let base = String(format: t("Ảnh vết thương ngày %@"), date)
        return entry.flaggedForReview ? "\(base), \(t("Cần theo dõi"))" : base
    }

    // MARK: - Data source

    private var dataSourceCard: some View {
        HomeSummaryCard(
            icon: "doc.text.magnifyingglass",
            iconColor: .accentColor,
            title: "Nguồn dữ liệu"
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text(viewModel.profile?.sourceName ?? t("Chưa có báo cáo y tế nào."))
                    .appFont(size: 15, weight: .medium)
                    .foregroundColor(Color(.label))
                    .fixedSize(horizontal: false, vertical: true)

                if let updated = viewModel.profile?.lastUpdated {
                    Text(String(format: t("Cập nhật lần cuối: %@"), Self.dateFormatter.string(from: updated)))
                        .appFont(size: 13)
                        .foregroundColor(Color(.secondaryLabel))
                }

                HStack(spacing: 6) {
                    Image(systemName: "lock.shield.fill")
                        .appFont(size: 13)
                    Text("Dữ liệu không rời khỏi thiết bị này")
                        .appFont(size: 13, weight: .medium)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundColor(.green)
            }
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

#Preview {
    HomeDashboardView(
        viewModel: HomeViewModel(
            profileRepository: MockProfileRepository(),
            profileUpdateRepository: InMemoryProfileUpdateRepository(),
            woundLogRepository: InMemoryWoundLogRepository(),
            patientID: UUID()
        )
    )
}
