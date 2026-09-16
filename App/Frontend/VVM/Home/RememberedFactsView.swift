import SwiftUI

/// The full list of durable facts the assistant carries between sessions — every
/// `ProposedProfileUpdate` the patient accepted, newest first.
///
/// This is deliberately *not* a section of `ProfileView`. Profile's memory card shows facts
/// gathered within the current conversation (`SessionFactStore`, in-memory and per-chat);
/// these survive relaunch. They are near-identical to look at and easy to confuse, so each
/// lives on the surface that owns it and says in its own words which kind it is.
struct RememberedFactsView: View {
    let facts: [HomeViewModel.RememberedFact]

    @AppStorage(AppLanguage.storageKey) private var appLanguageRaw = AppLanguage.vietnamese.rawValue
    private var appLanguage: AppLanguage { AppLanguage(rawValue: appLanguageRaw) ?? .vietnamese }
    private func t(_ key: String) -> String { key.localized(for: appLanguage) }

    var body: some View {
        ScrollView {
            if facts.isEmpty {
                ContentUnavailableView(
                    t("Trợ lý chưa ghi nhớ điều gì"),
                    systemImage: "brain.head.profile",
                    description: Text(t("Khi bạn kể một chi tiết trong lúc trò chuyện và xác nhận, nó sẽ xuất hiện ở đây."))
                )
                .padding(.top, 60)
            } else {
                VStack(spacing: 12) {
                    Text("Đây là những điều bạn đã xác nhận cho trợ lý ghi nhớ. Bạn có thể sửa hồ sơ bất cứ lúc nào.")
                        .appFont(size: 14)
                        .foregroundColor(Color(.secondaryLabel))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    ForEach(facts) { fact in
                        factRow(fact)
                    }
                }
                .padding(20)
            }
        }
        .navigationTitle("Trợ lý ghi nhớ về bạn")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func factRow(_ fact: HomeViewModel.RememberedFact) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(t(fact.label))
                .appFont(size: 12, weight: .semibold)
                .foregroundColor(Color(.secondaryLabel))

            Text(fact.value)
                .appFont(size: 16, weight: .medium)
                .foregroundColor(Color(.label))
                .fixedSize(horizontal: false, vertical: true)

            // The originating message, so a fact the patient does not recognise can be traced
            // back to what they actually said rather than having to be taken on trust.
            if !fact.sourceExcerpt.isEmpty {
                Text("“\(fact.sourceExcerpt)”")
                    .appFont(size: 13)
                    .foregroundColor(Color(.secondaryLabel))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(Self.dateFormatter.string(from: fact.recordedAt))
                .appFont(size: 12)
                .foregroundColor(Color(.tertiaryLabel))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .accessibilityElement(children: .combine)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}
