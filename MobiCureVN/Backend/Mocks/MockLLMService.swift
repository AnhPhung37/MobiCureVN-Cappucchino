//
//  MockLLMService.swift
//  MobiCureVN
//
//  Created by Anh Phung on 4/24/26.
//

import Foundation

class MockLLMService: LLMServiceProtocol {

    func stream(request: LLMRequest) -> AsyncStream<String> {
        AsyncStream { continuation in
            Task {
                let response = mockResponse(for: request.userMessage)
                for word in response.split(separator: " ") {
                    try? await Task.sleep(nanoseconds: 80_000_000) // 80ms per word
                    continuation.yield(String(word) + " ")
                }
                continuation.finish()
            }
        }
    }

    private func mockResponse(for query: String) -> String {
        let lower = query.lowercased()

        if lower.contains("nhiễm trùng") || lower.contains("infection") || lower.contains("mủ") {
            return """
            Dựa trên tài liệu y tế, các dấu hiệu nhiễm trùng vết mổ bao gồm: \
            đỏ, sưng, nóng, đau tăng, hoặc có mủ chảy ra. \
            Nếu bạn nhận thấy bất kỳ dấu hiệu nào trong số này, \
            hãy liên hệ ngay với y tá hoặc bác sĩ của bạn. \
            Không tự ý xử lý vết thương tại nhà khi có dấu hiệu nhiễm trùng.
            """
        }

        if lower.contains("đau") || lower.contains("pain") || lower.contains("đớn") {
            return """
            Đau sau phẫu thuật là điều bình thường trong những ngày đầu. \
            Hãy uống thuốc giảm đau theo đúng chỉ định của bác sĩ. \
            Nếu cơn đau tăng đột ngột hoặc không thuyên giảm sau khi uống thuốc, \
            vui lòng báo ngay cho đội ngũ y tế. \
            Bạn có thể chườm lạnh nhẹ xung quanh vùng phẫu thuật để giảm sưng.
            """
        }

        if lower.contains("ăn") || lower.contains("uống") || lower.contains("thức ăn") || lower.contains("diet") {
            return """
            Sau phẫu thuật đại trực tràng, chế độ ăn uống rất quan trọng. \
            Trong tuần đầu, nên ăn thức ăn mềm, dễ tiêu hóa như cháo, súp. \
            Tránh các thực phẩm có nhiều chất xơ thô, đồ cay, và đồ uống có ga. \
            Uống đủ 2 lít nước mỗi ngày để hỗ trợ quá trình hồi phục.
            """
        }

        if lower.contains("vết mổ") || lower.contains("băng") || lower.contains("wound") {
            return """
            Vết mổ cần được giữ khô và sạch trong 48 giờ đầu sau phẫu thuật. \
            Thay băng theo hướng dẫn của y tá, thường là mỗi 1-2 ngày. \
            Quan sát vết mổ hàng ngày để phát hiện sớm các dấu hiệu bất thường. \
            Tránh để vết mổ tiếp xúc với nước khi tắm trong tuần đầu tiên.
            """
        }

        return """
        Tôi hiểu câu hỏi của bạn về quá trình hồi phục sau phẫu thuật. \
        Dựa trên hướng dẫn chăm sóc sau phẫu thuật, \
        tôi khuyên bạn nên liên hệ với y tá nếu bạn không chắc chắn về \
        bất kỳ triệu chứng nào. \
        Sức khỏe và sự an toàn của bạn là ưu tiên hàng đầu của chúng tôi.
        """
    }
}
