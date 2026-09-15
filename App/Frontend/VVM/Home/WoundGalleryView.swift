import SwiftUI
import UIKit

/// Every wound photo the patient has captured, newest first — the "space to store all uploaded
/// wound photos" from #54.
///
/// Read-only by design. Photos are still created only by attaching an image in chat, where
/// `WoundAnalysisService` and the guardrail path already run; adding a capture button here
/// would create a second route into wound analysis with its own safety framing to get right.
struct WoundGalleryView: View {
    let entries: [WoundLogEntry]
    @State private var selected: WoundLogEntry?

    @AppStorage(AppLanguage.storageKey) private var appLanguageRaw = AppLanguage.vietnamese.rawValue
    private var appLanguage: AppLanguage { AppLanguage(rawValue: appLanguageRaw) ?? .vietnamese }
    private func t(_ key: String) -> String { key.localized(for: appLanguage) }

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 12)]

    var body: some View {
        ScrollView {
            if entries.isEmpty {
                ContentUnavailableView(
                    t("Chưa có ảnh vết thương"),
                    systemImage: "photo.on.rectangle.angled",
                    description: Text(t("Đính kèm ảnh trong màn hình trò chuyện để trợ lý ghi lại."))
                )
                .padding(.top, 60)
            } else {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(entries) { entry in
                        Button {
                            selected = entry
                        } label: {
                            galleryCell(entry)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(cellLabel(entry))
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle("Ảnh vết thương")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selected) { entry in
            WoundDetailSheet(entry: entry)
        }
    }

    private func galleryCell(_ entry: WoundLogEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            WoundThumbnail(url: entry.imageReference, size: 104)
                .frame(maxWidth: .infinity)

            Text(Self.dateFormatter.string(from: entry.capturedAt))
                .appFont(size: 12, weight: .medium)
                .foregroundColor(Color(.secondaryLabel))

            if entry.flaggedForReview {
                // Icon + text, not colour alone, so the flag survives colour-blind viewing.
                HStack(spacing: 3) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("Cần theo dõi")
                }
                .appFont(size: 10, weight: .semibold)
                .foregroundColor(.orange)
            }
        }
    }

    private func cellLabel(_ entry: WoundLogEntry) -> String {
        let date = Self.dateFormatter.string(from: entry.capturedAt)
        let base = String(format: t("Ảnh vết thương ngày %@"), date)
        return entry.flaggedForReview ? "\(base), \(t("Cần theo dõi"))" : base
    }

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

/// One photo with what the model observed in it.
///
/// Findings are framed as observations to show a clinician, never as a conclusion — the model
/// is an assistant, not a diagnostician, and a full-screen list of findings is exactly where
/// that distinction is easiest to lose.
private struct WoundDetailSheet: View {
    let entry: WoundLogEntry
    @Environment(\.dismiss) private var dismiss

    @AppStorage(AppLanguage.storageKey) private var appLanguageRaw = AppLanguage.vietnamese.rawValue
    private var appLanguage: AppLanguage { AppLanguage(rawValue: appLanguageRaw) ?? .vietnamese }
    private func t(_ key: String) -> String { key.localized(for: appLanguage) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let image = UIImage(contentsOfFile: entry.imageReference.path) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .accessibilityHidden(true)
                    }

                    Text(WoundGalleryView.dateFormatter.string(from: entry.capturedAt))
                        .appFont(size: 15, weight: .semibold)
                        .foregroundColor(Color(.label))

                    if entry.flaggedForReview {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text("Cần theo dõi")
                        }
                        .appFont(size: 13, weight: .semibold)
                        .foregroundColor(.orange)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.orange.opacity(0.15)))
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(findings, id: \.label) { finding in
                            detailRow(finding.label, finding.value)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color(.secondarySystemBackground))
                    )

                    Text("Đây là ghi nhận của trợ lý, không phải chẩn đoán. Hãy cho nhân viên y tế xem nếu bạn lo lắng.")
                        .appFont(size: 13)
                        .foregroundColor(Color(.secondaryLabel))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
            }
            .navigationTitle("Ảnh vết thương")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .appFont(size: 22)
                            .foregroundColor(Color(.tertiaryLabel))
                    }
                    .accessibilityLabel(t("Đóng"))
                }
            }
        }
    }

    /// Fields the model did not report are dropped rather than shown as "Not reported", the
    /// same suppression `ProfileView.woundDetail` applies.
    private var findings: [(label: String, value: String)] {
        [
            ("Màu stoma", entry.stomaColor),
            ("Thay đổi kích thước", entry.stomaSizeChange),
            ("Da xung quanh", entry.surroundingSkin),
            ("Dịch tiết", entry.outputAppearance),
            ("Độ kín của túi", entry.bagSeal),
            ("Sưng / lồi", entry.swellingOrProtrusion),
            ("Ghi nhận khác", entry.otherObservations)
        ].filter { $0.1 != WoundFindingsParser.notReported && !$0.1.isEmpty }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(t(label))
                .appFont(size: 12, weight: .medium)
                .foregroundColor(Color(.secondaryLabel))
            Text(value)
                .appFont(size: 15)
                .foregroundColor(Color(.label))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// A wound photo loaded from disk. A missing file — an entry that outlived its JPEG — falls
/// back to a placeholder rather than crashing, matching `ProfileView.woundThumbnail(_:)`.
struct WoundThumbnail: View {
    let url: URL
    var size: CGFloat

    var body: some View {
        Group {
            if let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image)
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
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
