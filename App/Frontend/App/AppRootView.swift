import SwiftUI

struct AppRootView: View {
    @AppStorage(AppearanceMode.storageKey) private var appearanceModeRaw = AppearanceMode.light.rawValue
    @AppStorage(AppLanguage.storageKey) private var appLanguageRaw = AppLanguage.vietnamese.rawValue
    @AppStorage(OnboardingState.storageKey) private var hasCompletedOnboarding = false
    @AppStorage(TextSizeOption.storageKey) private var textSizeRaw = TextSizeOption.large.rawValue

    var body: some View {
        Group {
            if hasCompletedOnboarding {
                HomeView()
            } else {
                OnboardingView()
            }
        }
        .preferredColorScheme(appearanceMode.colorScheme)
        .environment(\.locale, appLanguage.locale)
        .environment(\.textSizeScale, textSize.scaleFactor)
    }

    private var appearanceMode: AppearanceMode {
        AppearanceMode(rawValue: appearanceModeRaw) ?? .light
    }

    private var appLanguage: AppLanguage {
        AppLanguage(rawValue: appLanguageRaw) ?? .vietnamese
    }

    private var textSize: TextSizeOption {
        TextSizeOption(rawValue: textSizeRaw) ?? .large
    }
}
