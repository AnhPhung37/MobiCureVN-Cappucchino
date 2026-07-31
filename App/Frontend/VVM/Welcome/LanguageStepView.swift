import SwiftUI

struct LanguageStepView: View {
    @Binding var selectedLanguage: AppLanguage

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "globe")
                .appFont(size: 40)
                .foregroundColor(.cyan)

            VStack(spacing: 8) {
                Text("Chọn ngôn ngữ")
                    .appFont(size: 24, weight: .bold, design: .rounded)
                Text("Bạn có thể đổi lại sau trong Hồ sơ.")
                    .appFont(size: 14)
                    .foregroundColor(Color(.secondaryLabel))
            }
            .multilineTextAlignment(.center)

            VStack(spacing: 12) {
                languageOption(.vietnamese, title: "Tiếng Việt")
                languageOption(.english, title: "English")
            }
            .padding(.horizontal, 24)

            Spacer()
            Spacer()
        }
    }

    private func languageOption(_ language: AppLanguage, title: String) -> some View {
        let isSelected = selectedLanguage == language
        return Button {
            selectedLanguage = language
        } label: {
            HStack {
                Text(title)
                    .appFont(size: 16, weight: .semibold)
                    .foregroundColor(isSelected ? .white : Color(.label))
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.white)
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isSelected ? Color.cyan : Color(.secondarySystemBackground))
            )
        }
    }
}

#Preview {
    LanguageStepView(selectedLanguage: .constant(.vietnamese))
}
