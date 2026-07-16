import SwiftUI
import Translation

struct HomeView: View {

    @State private var selectedTab = 1
    // Observed so the tab-bar UI can react to translation readiness if needed in future.
    @ObservedObject private var translationService = AppConfig.translationService

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeContentView()
                .tabItem {
                    Image(systemName: "house.fill")
                    Text("Home")
                }
                .tag(0)

            ChatView()
                .tabItem {
                    Image(systemName: "message.fill")
                    Text("Chat")
                }
                .tag(1)

            ProfileView()
                .tabItem {
                    Image(systemName: "person.crop.circle.fill")
                    Text("Profile")
                }
                .tag(2)
        }
        .tint(.accentColor)
        // MARK: - Translation session lifecycle
        // Anchored here (on the persistent TabView) so sessions remain valid no matter
        // which tab is currently active. Previously attached to ChatView, which caused:
        //   "Fatal error: Attempted to use TranslationSession after the view it was
        //    attached to has disappeared"
        // whenever the user switched tabs while a translation was in-flight.
        .translationTask(TranslationService.viToEnConfiguration) { session in
            AppConfig.translationService.configure(viToEn: session)
        }
        .translationTask(TranslationService.enToViConfiguration) { session in
            AppConfig.translationService.configure(enToVi: session)
        }
        // Check device language pack availability once at startup.
        .task {
            await AppConfig.translationService.checkLanguageAvailability()
        }
    }
}

#Preview {
    HomeView()
}
