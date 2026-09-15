import SwiftUI
import Translation

struct HomeView: View {
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
    HomeView()
}
