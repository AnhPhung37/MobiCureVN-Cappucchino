import Foundation

/// One visual block of an assistant reply, as laid out by `AssistantReplyCard`.
nonisolated enum ReplyBlock: Equatable {
    case heading(String)
    case paragraph(String)
    /// A numbered item. `title` is set only when the item opens with a bold phrase set off from
    /// the rest (`1. **Ăn đủ đạm:** cá, trứng…`); `details` are the bullets nested under it.
    case step(number: String, title: String?, text: String?, details: [String])
    case bullets([String])

    var isStep: Bool {
        if case .step = self { return true }
        return false
    }
}

/// Splits the model's Markdown answer into blocks the reply card can give room to.
///
/// Rendered as a single `Text`, a multi-step answer came out as one dense paragraph with its
/// list markers inline. This only moves heading and list markers into the layout: every word of
/// the answer still reaches the screen, and inline Markdown (bold, italics) is left in place for
/// `Text` to render.
///
/// Deliberately small — line-based, with no nesting beyond bullets under a numbered step. Draft
/// text arrives mid-line while streaming, so anything it cannot classify falls back to a
/// paragraph rather than being dropped.
nonisolated enum ReplyBlockParser {

    static func parse(_ markdown: String) -> [ReplyBlock] {
        var builder = Builder()
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        for line in normalized.components(separatedBy: "\n") {
            builder.consume(line)
        }
        return builder.finish()
    }

    /// Splits off the closing paragraph when it points the patient to a doctor or nurse.
    ///
    /// The system prompt has the model end medical answers with a consult-your-provider line,
    /// and the truncation notice restores one; at the bottom of a long reply it is easy to miss,
    /// so the card lifts it into a caution box. A one-paragraph answer is left alone — boxing the
    /// entire reply would say nothing.
    static func separatingProviderNote(from blocks: [ReplyBlock]) -> (blocks: [ReplyBlock], note: String?) {
        guard blocks.count >= 2,
              case let .paragraph(text)? = blocks.last,
              mentionsCareProvider(text) else {
            return (blocks, nil)
        }
        return (Array(blocks.dropLast()), text)
    }

    private static let careProviderTerms = [
        "bác sĩ", "nhân viên y tế", "chuyên gia y tế", "cơ sở y tế", "điều dưỡng",
        "doctor", "healthcare provider", "health care provider", "medical professional", "nurse",
    ]

    static func mentionsCareProvider(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return careProviderTerms.contains { lowered.contains($0) }
    }

    // MARK: - Line classification

    /// `## Title`, or a line that is bold from end to end (`**Chế độ ăn:**`), which is how the
    /// model usually titles a section.
    static func heading(in line: String) -> String? {
        let hashes = line.prefix { $0 == "#" }.count
        if hashes > 0 {
            let rest = line.dropFirst(hashes)
            guard hashes <= 6, rest.first?.isWhitespace == true else { return nil }
            let text = rest.trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : strippingTrailingColon(text)
        }

        guard line.hasPrefix("**") else { return nil }
        var inner = line.dropFirst(2)
        if inner.hasSuffix("**:") {
            inner = inner.dropLast(3)
        } else if inner.hasSuffix("**") {
            inner = inner.dropLast(2)
        } else {
            return nil
        }
        let text = inner.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !text.contains("**") else { return nil }
        return strippingTrailingColon(text)
    }

    /// `---`, `***`, `- - -`.
    static func isRule(_ line: String) -> Bool {
        let compact = line.filter { $0 != " " }
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    /// `1. text` or `1) text`. At most two digits and a space after the marker, so a line
    /// opening with "1.5 lít" or "2024." stays prose.
    static func orderedItem(in line: String) -> (number: String, text: String)? {
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        guard (1...2).contains(digits.count) else { return nil }
        let rest = line.dropFirst(digits.count)
        guard let marker = rest.first, marker == "." || marker == ")" else { return nil }
        let afterMarker = rest.dropFirst()
        guard afterMarker.first?.isWhitespace == true else { return nil }
        let text = afterMarker.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return (String(digits), text)
    }

    /// `- text`, `* text`, `• text`, `+ text`. The space is required, so `**bold**` stays prose.
    static func bulletItem(in line: String) -> String? {
        guard let marker = line.first, "-*•+".contains(marker) else { return nil }
        let rest = line.dropFirst()
        guard rest.first?.isWhitespace == true else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    /// `**Ăn đủ đạm:** cá, trứng` → ("Ăn đủ đạm", "cá, trứng"). Only a bold phrase set off by a
    /// colon or dash — or making up the whole item — is a title; a bold word inside a running
    /// sentence ("**Sốt** trên 38,5°C…") stays part of the sentence.
    static func splitTitle(_ text: String) -> (title: String?, text: String?) {
        guard text.hasPrefix("**") else { return (nil, text) }
        let afterOpen = text.dropFirst(2)
        guard let close = afterOpen.range(of: "**") else { return (nil, text) }

        let rawTitle = afterOpen[..<close.lowerBound].trimmingCharacters(in: .whitespaces)
        var rest = afterOpen[close.upperBound...].trimmingCharacters(in: .whitespaces)
        let restOpensWithSeparator = rest.first.map { ":-–—".contains($0) } ?? false

        guard !rawTitle.isEmpty, rest.isEmpty || rawTitle.hasSuffix(":") || restOpensWithSeparator else {
            return (nil, text)
        }
        if restOpensWithSeparator {
            rest = rest.dropFirst().trimmingCharacters(in: .whitespaces)
        }
        let title = strippingTrailingColon(rawTitle)
        guard !title.isEmpty else { return (nil, text) }
        return (title, rest.isEmpty ? nil : rest)
    }

    private static func strippingTrailingColon(_ text: String) -> String {
        guard text.hasSuffix(":") else { return text }
        return text.dropLast().trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Builder

    private nonisolated struct Builder {
        private var blocks: [ReplyBlock] = []
        private var paragraph: [String] = []
        /// The step or bullet list that indented, or directly following, lines still belong to.
        private var openList: Int?
        private var previousLineWasBlank = false

        mutating func consume(_ rawLine: String) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let indent = rawLine.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            defer { previousLineWasBlank = line.isEmpty }

            if line.isEmpty {
                flushParagraph()
            } else if let text = ReplyBlockParser.heading(in: line) {
                flushParagraph()
                blocks.append(.heading(text))
                openList = nil
            } else if ReplyBlockParser.isRule(line) {
                flushParagraph()
                openList = nil
            } else if let item = ReplyBlockParser.orderedItem(in: line) {
                flushParagraph()
                if indent >= 2, let open = openList, blocks[open].isStep {
                    appendDetail("\(item.number). \(item.text)", to: open)
                } else {
                    let parts = ReplyBlockParser.splitTitle(item.text)
                    blocks.append(.step(number: item.number, title: parts.title, text: parts.text, details: []))
                    openList = blocks.count - 1
                }
            } else if let text = ReplyBlockParser.bulletItem(in: line) {
                flushParagraph()
                addBullet(text, indent: indent)
            } else if paragraph.isEmpty, let open = openList, indent >= 2 || !previousLineWasBlank {
                appendContinuation(line, to: open)
            } else {
                if paragraph.isEmpty { openList = nil }
                paragraph.append(line)
            }
        }

        mutating func finish() -> [ReplyBlock] {
            flushParagraph()
            return blocks
        }

        private mutating func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph = []
        }

        /// A bullet under a numbered step (indented, or with no blank line between) becomes one
        /// of its details; otherwise it joins or starts a plain bullet list.
        private mutating func addBullet(_ text: String, indent: Int) {
            if let open = openList {
                switch blocks[open] {
                case .step where indent >= 2 || !previousLineWasBlank:
                    appendDetail(text, to: open)
                    return
                case .bullets(var items):
                    items.append(text)
                    blocks[open] = .bullets(items)
                    return
                default:
                    break
                }
            }
            blocks.append(.bullets([text]))
            openList = blocks.count - 1
        }

        private mutating func appendDetail(_ text: String, to index: Int) {
            guard case let .step(number, title, body, details) = blocks[index] else { return }
            blocks[index] = .step(number: number, title: title, text: body, details: details + [text])
        }

        private mutating func appendContinuation(_ line: String, to index: Int) {
            switch blocks[index] {
            case let .step(number, title, body, details):
                if let last = details.last {
                    blocks[index] = .step(number: number, title: title, text: body,
                                          details: Array(details.dropLast()) + [last + "\n" + line])
                } else {
                    blocks[index] = .step(number: number, title: title,
                                          text: body.map { $0 + "\n" + line } ?? line, details: details)
                }
            case var .bullets(items):
                items[items.count - 1] += "\n" + line
                blocks[index] = .bullets(items)
            default:
                paragraph.append(line)
            }
        }
    }
}
