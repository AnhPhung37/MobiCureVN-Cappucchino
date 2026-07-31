import SwiftUI

struct DisclaimerStepView: View {
    @Binding var agreed: Bool

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 10) {
                Image(systemName: "hand.raised.fill")
                    .appFont(size: 32)
                    .foregroundColor(.cyan)

                Text("Lưu ý y tế quan trọng")
                    .appFont(size: 22, weight: .bold, design: .rounded)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 16)

            ScrollView {
                Text("""
                MobiCure cung cấp thông tin và gợi ý mang tính tham khảo về quá trình hồi phục sau phẫu thuật đại trực tràng. Đây không phải là chẩn đoán hay tư vấn y tế và không thay thế cho bác sĩ hoặc đội ngũ chăm sóc của bạn.

                Luôn tham khảo ý kiến bác sĩ trước khi thay đổi cách chăm sóc, dùng thuốc hoặc chế độ ăn uống.

                Nếu bạn gặp triệu chứng nghiêm trọng hoặc khẩn cấp (sốt cao, chảy máu nhiều, đau dữ dội...), hãy gọi cấp cứu hoặc đến cơ sở y tế gần nhất ngay lập tức.
                """)
                    .appFont(size: 14)
                    .foregroundColor(Color(.label))
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(16)
            }
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )

            Toggle(isOn: $agreed) {
                Text("Tôi đã đọc và hiểu rằng đây là thông tin tham khảo, không thay thế tư vấn y tế chuyên môn.")
                    .appFont(size: 13)
                    .foregroundColor(Color(.label))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.switch)
            .tint(.cyan)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
    }
}

#Preview {
    DisclaimerStepView(agreed: .constant(false))
}
