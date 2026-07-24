import SwiftUI

struct AppRootView: View {
    @AppStorage(AppearanceMode.storageKey) private var appearanceModeRaw = AppearanceMode.light.rawValue
    @AppStorage(AppLanguage.storageKey) private var appLanguageRaw = AppLanguage.vietnamese.rawValue

    var body: some View {
        HomeView()
            .preferredColorScheme(appearanceMode.colorScheme)
            .environment(\.locale, appLanguage.locale)
    }

    private var appearanceMode: AppearanceMode {
        AppearanceMode(rawValue: appearanceModeRaw) ?? .light
    }

    private var appLanguage: AppLanguage {
        AppLanguage(rawValue: appLanguageRaw) ?? .vietnamese
    }
}
