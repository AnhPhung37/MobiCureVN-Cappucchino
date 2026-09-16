import XCTest
@testable import MobiCureVN

/// Tests for ReplyBlockParser — the Markdown-to-blocks split behind the assistant reply card.
/// The layout is cosmetic, but the parser sits between the model's answer and the patient, so
/// the property that matters most is that it never drops any of the answer's words.
final class ReplyBlockParserTests: XCTestCase {

    func testParagraphsSplitOnBlankLinesAndKeepSingleLineBreaks() {
        XCTAssertEqual(ReplyBlockParser.parse("Chào bạn.\nMình ở đây.\n\nĐoạn hai."), [
            .paragraph("Chào bạn.\nMình ở đây."),
            .paragraph("Đoạn hai."),
        ])
    }

    func testNumberedItemsOpeningWithABoldPhraseBecomeTitledSteps() {
        let markdown = """
        1. **Ăn đủ đạm mỗi bữa:** Cá, trứng, thịt nạc.
        2. **Uống 1,5–2 lít nước** – chia nhỏ trong ngày.
        3. **Nghỉ ngơi**
        """
        XCTAssertEqual(ReplyBlockParser.parse(markdown), [
            .step(number: "1", title: "Ăn đủ đạm mỗi bữa", text: "Cá, trứng, thịt nạc.", details: []),
            .step(number: "2", title: "Uống 1,5–2 lít nước", text: "chia nhỏ trong ngày.", details: []),
            .step(number: "3", title: "Nghỉ ngơi", text: nil, details: []),
        ])
    }

    func testBoldWordInsideASentenceIsNotTreatedAsATitle() {
        XCTAssertEqual(ReplyBlockParser.parse("1. **Sốt** trên 38,5°C cần báo bác sĩ."), [
            .step(number: "1", title: nil, text: "**Sốt** trên 38,5°C cần báo bác sĩ.", details: []),
        ])
    }

    func testNestedBulletsAndContinuationLinesStayWithTheirStep() {
        let markdown = """
        1. **Tạm tránh:**
           - đồ chiên rán
           - rượu bia
        2. Ngủ đủ giấc
        và đi lại nhẹ nhàng.
        """
        XCTAssertEqual(ReplyBlockParser.parse(markdown), [
            .step(number: "1", title: "Tạm tránh", text: nil, details: ["đồ chiên rán", "rượu bia"]),
            .step(number: "2", title: nil, text: "Ngủ đủ giấc\nvà đi lại nhẹ nhàng.", details: []),
        ])
    }

    func testHeadingsBulletListsAndRules() {
        let markdown = """
        ## Chế độ ăn
        **Nên ăn:**
        - Cháo
        * Súp

        ---
        Hết.
        """
        XCTAssertEqual(ReplyBlockParser.parse(markdown), [
            .heading("Chế độ ăn"),
            .heading("Nên ăn"),
            .bullets(["Cháo", "Súp"]),
            .paragraph("Hết."),
        ])
    }

    func testDecimalsYearsAndBoldTextAreNotListMarkers() {
        let markdown = "1.5 lít nước mỗi ngày.\n2024. Năm phẫu thuật.\n**Quan trọng** là uống đều."
        XCTAssertEqual(ReplyBlockParser.parse(markdown), [.paragraph(markdown)])
    }

    func testClosingCareProviderParagraphIsSeparatedAsANote() {
        let blocks = ReplyBlockParser.parse("Uống nhiều nước.\n\nNếu sốt, hãy liên hệ bác sĩ của bạn.")
        let layout = ReplyBlockParser.separatingProviderNote(from: blocks)

        XCTAssertEqual(layout.blocks, [.paragraph("Uống nhiều nước.")])
        XCTAssertEqual(layout.note, "Nếu sốt, hãy liên hệ bác sĩ của bạn.")
    }

    func testProviderNoteIsNotSplitFromASingleParagraphOrAList() {
        let single = ReplyBlockParser.parse("Hãy hỏi bác sĩ của bạn.")
        XCTAssertNil(ReplyBlockParser.separatingProviderNote(from: single).note)

        let endsInList = ReplyBlockParser.parse("Dấu hiệu:\n\n- sốt\n- gọi bác sĩ")
        XCTAssertNil(ReplyBlockParser.separatingProviderNote(from: endsInList).note)
    }

    @MainActor
    func testNoWordOfTheAnswerIsDropped() {
        let mixed = """
        Chào bạn, sau mổ 12 ngày:

        ### Kế hoạch 3 bước
        1. **Ăn đủ đạm:** cá, trứng
           - đậu hũ
        2) Uống nước
           thành nhiều lần.
        * Tránh rượu bia
        + Tránh đồ chiên
        ***
        _(Câu trả lời đã bị cắt — hãy hỏi lại nhân viên y tế.)_
        """
        let samples = Array(EmergencyResponses.templates.values) + [mixed]

        for sample in samples {
            let rendered = ReplyBlockParser.parse(sample).map(renderedText).joined(separator: " ")
            for word in words(in: sample) {
                XCTAssertTrue(rendered.contains(word), "Dropped “\(word)” from:\n\(sample)")
            }
        }
    }

    // MARK: - Helpers

    private func renderedText(_ block: ReplyBlock) -> String {
        switch block {
        case .heading(let text), .paragraph(let text):
            return text
        case let .step(number, title, text, details):
            return ([number, title, text].compactMap { $0 } + details).joined(separator: " ")
        case .bullets(let items):
            return items.joined(separator: " ")
        }
    }

    /// The sample's words with Markdown markers and edge punctuation removed — the parts the
    /// parser is allowed to turn into layout.
    private func words(in markdown: String) -> [String] {
        markdown
            .split(whereSeparator: \.isWhitespace)
            .map { $0.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: CharacterSet(charactersIn: ".:)–—-*•#+")) }
            .filter { !$0.isEmpty }
    }
}
