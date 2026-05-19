import SwiftUI

struct ProfileView: View {
    @State var viewModel: ProfileViewModel

    init(viewModel: ProfileViewModel = ProfileViewModel(repository: MockProfileRepository())) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if viewModel.isLoading {
                        ProgressView("Loading profile...")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    } else if let profile = viewModel.profile {
                        headerCard(profile)
                        profileDetails(profile)
                        notesCard(title: "Care notes", items: profile.careNotes, icon: "checkmark.circle.fill")
                        notesCard(title: "Warning signs", items: profile.warningSigns, icon: "exclamationmark.triangle.fill")
                        sourceCard(profile)
                    } else if let error = viewModel.errorMessage {
                        Text(error)
                            .foregroundColor(.red)
                            .padding()
                    } else {
                        ContentUnavailableView("No profile", systemImage: "person.crop.circle.badge.questionmark", description: Text("Profile not loaded."))
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
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.large)
            .task {
                await viewModel.load()
            }
        }
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
            detailRow(label: "Age", value: "\(profile.age)")
            detailRow(label: "Gender", value: profile.gender)
            detailRow(label: "Procedure", value: profile.procedure)
            detailRow(label: "Last updated", value: Self.dateFormatter.string(from: profile.lastUpdated))
            VStack(alignment: .leading, spacing: 8) {
                Text("Report summary")
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
                Text(title)
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

    private func sourceCard(_ profile: PatientProfile) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Data source")
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
