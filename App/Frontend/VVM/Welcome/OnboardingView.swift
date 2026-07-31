import SwiftUI

/// First-launch flow: welcome → medical disclaimer consent → language choice.
/// Shown once by `AppRootView` (gated on `OnboardingState.storageKey`), then never again.
struct OnboardingView: View {
    @AppStorage(OnboardingState.storageKey) private var hasCompletedOnboarding = false
    @AppStorage(AppLanguage.storageKey) private var appLanguageRaw = AppLanguage.vietnamese.rawValue

    @State private var page = 0
    @State private var hasAgreedToDisclaimer = false
    @State private var selectedLanguage: AppLanguage = AppLanguage.current

    private let totalPages = 3

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                WelcomeStepView()
                    .tag(0)
                DisclaimerStepView(agreed: $hasAgreedToDisclaimer)
                    .tag(1)
                LanguageStepView(selectedLanguage: $selectedLanguage)
                    .tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            pageIndicator
                .padding(.top, 8)

            continueButton
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 32)
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        // Onboarding renders before the language is committed to AppLanguage.storageKey, so it
        // tracks the in-progress selection directly rather than the persisted app-wide locale.
        .environment(\.locale, selectedLanguage.locale)
    }

    private var pageIndicator: some View {
        HStack(spacing: 8) {
            ForEach(0..<totalPages, id: \.self) { index in
                Capsule()
                    .fill(index == page ? Color.cyan : Color(.systemGray4))
                    .frame(width: index == page ? 20 : 8, height: 8)
            }
        }
        .animation(.easeInOut, value: page)
    }

    private var isContinueDisabled: Bool {
        page == 1 && !hasAgreedToDisclaimer
    }

    private var continueButton: some View {
        Button(action: advance) {
            Text(page == totalPages - 1 ? "Bắt đầu" : "Tiếp tục")
                .appFont(size: 16, weight: .semibold)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(isContinueDisabled ? Color.cyan.opacity(0.4) : Color.cyan)
                )
        }
        .disabled(isContinueDisabled)
    }

    private func advance() {
        if page < totalPages - 1 {
            withAnimation { page += 1 }
        } else {
            appLanguageRaw = selectedLanguage.rawValue
            hasCompletedOnboarding = true
        }
    }
}

#Preview {
    OnboardingView()
}
