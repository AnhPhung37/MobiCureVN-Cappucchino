//
//  MockLLMService.swift
//  MobiCureVN
//
//  Created by Anh Phung on 4/24/26.
//

import Foundation

nonisolated final class MockLLMService: LLMServiceProtocol {

    nonisolated func stream(request: LLMRequest) -> AsyncStream<String> {
        AsyncStream { continuation in
            let task = Task {
                let response = mockResponse(for: request.userMessage)
                for word in response.split(separator: " ") {
                    // Stop promptly when the consumer cancels, mirroring the real LLMService.
                    // (Task.sleep throws on cancellation, so without this the loop would
                    // otherwise dump the rest of the response instantly.)
                    if Task.isCancelled { break }
                    do {
                        try await Task.sleep(nanoseconds: 80_000_000) // 80ms per word
                    } catch {
                        break
                    }
                    continuation.yield(String(word) + " ")
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func mockResponse(for query: String) -> String {
        let lower = query.lowercased()

        if lower.contains("classify the language") {
            return classifyLanguage(query)
        }

        // Second-pass language confirmation ("Is the TEXT below written in X? yes/no").
        if lower.contains("is the text below written in") {
            return confirmLanguage(query)
        }

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

    // Stand-in for the real model's language classification used by LanguageValidationService.
    // A real LLM judges the DOMINANT language rather than flagging any single diacritic, so
    // this mirrors that: it classifies by the fraction of Vietnamese-signal words (diacritics
    // or accent-less function words), not by mere presence. This is what lets the mock model
    // the issue-#2 regression faithfully — an English sentence mentioning one Vietnamese
    // place name ("Đà Nẵng") classifies as english, not vietnamese.
    private func classifyLanguage(_ prompt: String) -> String {
        guard let range = prompt.range(of: "TEXT:") else { return "english" }
        let text = String(prompt[range.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let vietnameseDiacritics = "àáâãèéêìíòóôõùúýăđơưạảấầẩẫậắằẳẵặẹẻẽếềểễệỉịọỏốồổỗộớờởỡợụủứừửữựỳỵỷỹ"
        let commonVietnameseWords: Set<String> = ["toi", "khong", "bi", "dau", "va", "cua", "voi", "gi", "khi", "sau", "mo"]

        let words = text
            .split { !$0.isLetter && !vietnameseDiacritics.contains($0) }
            .map(String.init)
        guard !words.isEmpty else { return "english" }

        let vietnameseWords = words.filter { word in
            word.contains(where: { vietnameseDiacritics.contains($0) })
                || commonVietnameseWords.contains(word)
        }
        let density = Double(vietnameseWords.count) / Double(words.count)

        // Dominant-language judgement: a minority of Vietnamese-signal words (a stray place
        // name in an English sentence) reads as english.
        return density >= 0.30 ? "vietnamese" : "english"
    }

    // Stand-in for the real model's second-pass yes/no confirmation. The prompt asks
    // "Is the TEXT below written in {Vietnamese|English}?"; answer consistently with
    // `classifyLanguage` so the two-pass verify path is deterministic in mock mode.
    private func confirmLanguage(_ prompt: String) -> String {
        let asksVietnamese = prompt.lowercased().contains("written in vietnamese")
        let classified = classifyLanguage(prompt) // "vietnamese" or "english"
        let textIsVietnamese = classified == "vietnamese"
        return textIsVietnamese == asksVietnamese ? "yes" : "no"
    }
}
