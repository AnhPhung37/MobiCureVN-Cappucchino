import SwiftUI

struct AppRootView: View {
    @AppStorage(AppearanceMode.storageKey) private var appearanceModeRaw = AppearanceMode.light.rawValue

    var body: some View {
        HomeView()
            .preferredColorScheme(appearanceMode.colorScheme)
    }

    private var appearanceMode: AppearanceMode {
        AppearanceMode(rawValue: appearanceModeRaw) ?? .light
    }
}
