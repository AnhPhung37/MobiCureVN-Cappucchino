import SwiftUI
import Translation

/// The post-onboarding shell. Chat is the app's main screen — a patient opening the app is
/// usually here to ask something, not to read a dashboard — so `ChatWorkspaceView` is the root
/// and Home is reached from its header.
///
/// Owns the process-wide translation session setup, which needs a stable host above the chat
/// surface rather than inside a screen that comes and goes.
struct AppShellView: View {
    var body: some View {
        ChatWorkspaceView()
            .translationTask(TranslationService.viToEnConfiguration) { session in
                AppConfig.translationService.configure(viToEn: session)
            }
            .translationTask(TranslationService.enToViConfiguration) { session in
                AppConfig.translationService.configure(enToVi: session)
            }
            .task {
                await AppConfig.translationService.checkLanguageAvailability()
            }
    }
}

#Preview {
    AppShellView()
}
