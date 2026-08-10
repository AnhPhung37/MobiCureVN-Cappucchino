import SwiftUI

struct WelcomeStepView: View {
    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image("doctor")
                .resizable()
                .scaledToFit()
                .frame(height: 200)
                .padding(28)
                .background(
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.cyan.opacity(0.25), Color.blue.opacity(0.15)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )

            VStack(spacing: 12) {
                Text("Chào mừng đến với MobiCure")
                    .appFont(size: 26, weight: .bold, design: .rounded)
                    .multilineTextAlignment(.center)

                Text("Người bạn đồng hành cùng bạn trong hành trình hồi phục sau phẫu thuật đại trực tràng.")
                    .appFont(size: 15)
                    .foregroundColor(Color(.secondaryLabel))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 32)

            Spacer()
            Spacer()
        }
    }
}

#Preview {
    WelcomeStepView()
}
