import SwiftUI

struct AppRoot: View {
    var body: some View {
        TabView {
            ChatView(llmService: AppConfig.llmService)
                .tabItem {
                    Image(systemName: "bubble.left.and.bubble.right")
                    Text("Chat")
                }

            ProfileView(viewModel: ProfileViewModel(repository: MockProfileRepository()))
                .tabItem {
                    Image(systemName: "person.crop.circle")
                    Text("Profile")
                }
        }
    }
}

#Preview {
    AppRoot()
}
