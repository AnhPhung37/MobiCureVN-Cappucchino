import PhotosUI
import SwiftUI
import UIKit

/// Patient-editable identity fields: photo, name, age, gender.
///
/// Scope is deliberate. These are the four things the patient knows better than any report does,
/// and none of them is clinical — diagnosis, procedure and recovery stage are absent by design,
/// because those only ever change via an ingested clinician report or an explicitly confirmed
/// `ProposedProfileUpdate`. Nothing here can rewrite a clinical field.
///
/// Edits are staged locally and only written on Save, so backing out of the sheet leaves the
/// stored profile untouched.
struct ProfileEditView: View {

    let initial: PatientProfile.Edits
    let onSave: (PatientProfile.Edits) async -> Void

    @Environment(\.dismiss) private var dismiss

    @AppStorage(AppLanguage.storageKey) private var appLanguageRaw = AppLanguage.vietnamese.rawValue
    private var appLanguage: AppLanguage { AppLanguage(rawValue: appLanguageRaw) ?? .vietnamese }
    private func t(_ key: String) -> String { key.localized(for: appLanguage) }

    @State private var name: String = ""
    @State private var ageText: String = ""
    @State private var gender: ProfileGender = .unspecified
    /// Exact wording for `.other`, so picking "Other" never silently discards a value the
    /// patient (or an earlier confirmed proposal) wrote, e.g. "non-binary".
    @State private var genderDetail: String = ""
    @State private var photoData: Data?

    @State private var isShowingPhotoSourceDialog = false
    @State private var isShowingCameraPicker = false
    @State private var isShowingPhotoLibrary = false
    @State private var photoPickerItem: PhotosPickerItem?
    @State private var isSaving = false
    @State private var didSeed = false

    private var edits: PatientProfile.Edits {
        PatientProfile.Edits(
            name: name,
            age: Int(ageText) ?? 0,
            gender: gender.storedValue(detail: genderDetail),
            photoData: photoData
        )
    }

    private var hasChanges: Bool { edits != initial }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    photoRow
                }

                Section(t("Thông tin cá nhân")) {
                    LabeledContent(t("Tên")) {
                        TextField(t("Chưa đặt"), text: $name)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                    }

                    LabeledContent(t("Tuổi")) {
                        TextField(t("Chưa đặt"), text: $ageText)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numberPad)
                            // Digits only, capped at a plausible human age: the field feeds an
                            // Int the prompt builder prints verbatim, so junk in is junk to the
                            // model. Filtering as-typed avoids a save-time error dialog.
                            .onChange(of: ageText) { _, newValue in
                                let digits = String(newValue.filter(\.isNumber).prefix(3))
                                let clamped = min(Int(digits) ?? 0, 120)
                                ageText = digits.isEmpty ? "" : String(clamped)
                            }
                    }
                }

                Section(t("Giới tính")) {
                    Picker(t("Giới tính"), selection: $gender) {
                        ForEach(ProfileGender.selectableCases, id: \.self) { option in
                            Text(t(option.displayKey)).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)

                    if gender == .other {
                        TextField(t("Mô tả (không bắt buộc)"), text: $genderDetail)
                            .autocorrectionDisabled()
                    }
                }

                Section {
                    Text(t("Chỉ bạn mới thay đổi được những mục này. Chẩn đoán, thủ thuật và giai đoạn hồi phục chỉ thay đổi qua báo cáo của bác sĩ hoặc khi bạn xác nhận đề xuất từ trợ lý."))
                        .font(.footnote)
                        .foregroundColor(Color(.secondaryLabel))
                }
            }
            .navigationTitle(t("Chỉnh sửa hồ sơ"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(t("Huỷ")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(t("Lưu")) {
                        isSaving = true
                        Task {
                            await onSave(edits)
                            isSaving = false
                            dismiss()
                        }
                    }
                    .fontWeight(.semibold)
                    .disabled(!hasChanges || isSaving)
                }
            }
            .confirmationDialog(
                t("Ảnh đại diện"),
                isPresented: $isShowingPhotoSourceDialog,
                titleVisibility: .visible
            ) {
                Button(t("Chụp ảnh")) { isShowingCameraPicker = true }
                Button(t("Chọn từ thư viện")) { isShowingPhotoLibrary = true }
                if photoData != nil {
                    Button(t("Xoá ảnh"), role: .destructive) { photoData = nil }
                }
                Button(t("Huỷ"), role: .cancel) {}
            }
            .photosPicker(isPresented: $isShowingPhotoLibrary, selection: $photoPickerItem, matching: .images)
            .fullScreenCover(isPresented: $isShowingCameraPicker) {
                CameraImagePicker(image: cameraCaptureBinding)
                    .ignoresSafeArea()
            }
            .onChange(of: photoPickerItem) { _, newItem in
                guard let newItem else { return }
                Task { await loadPickedPhoto(newItem) }
            }
        }
        .environment(\.locale, appLanguage.locale)
        .onAppear(perform: seedFieldsFromInitialValue)
    }

    // MARK: - Photo

    private var photoRow: some View {
        HStack(spacing: 16) {
            Button {
                isShowingPhotoSourceDialog = true
            } label: {
                ZStack(alignment: .bottomTrailing) {
                    ProfileAvatar(photoData: photoData, name: name, diameter: 72)

                    Image(systemName: "camera.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(6)
                        .background(Circle().fill(Color.cyan))
                        .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(t("Ảnh đại diện"))

            VStack(alignment: .leading, spacing: 4) {
                Text(t("Ảnh đại diện"))
                    .font(.system(size: 15, weight: .semibold))
                Text(t("Chạm để chụp hoặc chọn ảnh."))
                    .font(.footnote)
                    .foregroundColor(Color(.secondaryLabel))
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }

    /// The picker hands back a fresh capture each time; `get` stays nil so re-presenting the
    /// camera never shows a stale image. Mirrors `ChatWorkspaceView.cameraCaptureBinding`.
    private var cameraCaptureBinding: Binding<UIImage?> {
        Binding(
            get: { nil },
            set: { newImage in
                guard let newImage else { return }
                photoData = newImage.attachmentJPEGData(maxDimension: 512)
            }
        )
    }

    private func loadPickedPhoto(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else { return }
        // Downscaled on the way in: an avatar is displayed at 72pt, and the raw asset would
        // otherwise be several MB sitting in the profile row's external storage.
        photoData = image.attachmentJPEGData(maxDimension: 512)
        photoPickerItem = nil
    }

    // MARK: - Seeding

    private func seedFieldsFromInitialValue() {
        // Seed exactly once. `onAppear` fires again when the camera cover or photo picker is
        // dismissed, and re-seeding there would resurrect a value the patient had just cleared.
        guard !didSeed else { return }
        didSeed = true
        name = initial.name
        ageText = initial.age > 0 ? String(initial.age) : ""
        photoData = initial.photoData
        let resolved = ProfileGender.matching(initial.gender)
        gender = resolved
        genderDetail = resolved == .other ? initial.gender : ""
    }
}

// MARK: - Gender

/// The gender options offered in the editor.
///
/// Stored values stay lowercase English (`"female"`, `"male"`, or the patient's own wording)
/// because that is what `ProfileUpdateExtractor` emits and what the prompt builder prints into
/// the system prompt — keeping one vocabulary means a value typed here and a value confirmed
/// from chat are indistinguishable downstream.
enum ProfileGender: Hashable {
    case female
    case male
    case other
    /// Nothing on file yet. Selectable only in the sense that it is the initial state.
    case unspecified

    static let selectableCases: [ProfileGender] = [.female, .male, .other]

    var displayKey: String {
        switch self {
        case .female: return "Nữ"
        case .male: return "Nam"
        case .other: return "Khác"
        case .unspecified: return "Chưa đặt"
        }
    }

    /// The string written to `PatientProfile.gender`.
    func storedValue(detail: String) -> String {
        switch self {
        case .female: return "female"
        case .male: return "male"
        case .unspecified: return ""
        case .other:
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "other" : trimmed
        }
    }

    /// Map a stored value back to an option. Accepts both the canonical English and the
    /// Vietnamese display words, so a profile written before this editor existed — or by a
    /// confirmed proposal phrased in either language — still lands on the right segment.
    static func matching(_ stored: String) -> ProfileGender {
        let key = stored.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return .unspecified }
        if ["female", "f", "woman", "nữ", "nu"].contains(key) { return .female }
        if ["male", "m", "man", "nam"].contains(key) { return .male }
        return .other
    }
}

// MARK: - Avatar

/// The patient's photo, falling back to the first letter of their name and then to a neutral
/// glyph. Shared by the editor and the Profile header so both always agree.
struct ProfileAvatar: View {
    let photoData: Data?
    let name: String
    var diameter: CGFloat = 64

    private var initial: String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return nil }
        return String(first).uppercased()
    }

    var body: some View {
        ZStack {
            Circle().fill(Color.cyan.opacity(0.15))

            if let photoData, let image = UIImage(data: photoData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if let initial {
                Text(initial)
                    .appFont(size: diameter * 0.38, weight: .bold)
                    .foregroundColor(.cyan)
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: diameter * 0.38))
                    .foregroundColor(.cyan)
            }
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
    }
}
