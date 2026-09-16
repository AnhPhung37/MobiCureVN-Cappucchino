import SwiftUI

/// An assistant turn laid out as a full-width card: who is speaking, the answer broken into
/// headings, numbered steps and lists, then the read-aloud button and sources.
///
/// Replaces the assistant bubble. Answers are often several steps long and are read on a phone
/// by patients recovering from surgery, many of them elderly. As 16pt text in a bubble capped
/// 48pt short of the screen edge, with 10pt of padding, a multi-step answer came out as one
/// tight block. The card uses the full width, sets body text at 18pt with extra line spacing,
/// and gives each numbered step its own row.
struct AssistantReplyCard: View {
    let message: ChatMessage
    /// True while the card shows draft text no guardrail has validated yet. The header says it
    /// is still being written, a caret trails the text, and the actions stay hidden until the
    /// final answer replaces the draft.
    var isStreaming: Bool = false
    var isSpeaking: Bool = false
    var onToggleSpeech: () -> Void = {}
    var hasSourceDocument: (MedicalSource) -> Bool = { _ in false }
    var onOpenSourceDocument: (MedicalSource) -> Void = { _ in }
    var onAcceptProfileUpdate: (ProposedProfileUpdate) -> Void = { _ in }
    var onDismissProfileUpdate: (ProposedProfileUpdate) -> Void = { _ in }

    private let cardShape = RoundedRectangle(cornerRadius: 24, style: .continuous)

    /// Covers the language, guardrail and retrieval stages too, which run before any draft text.
    private var isWriting: Bool { isStreaming || message.content.isEmpty }

    /// Emergency replies are the fixed `EmergencyResponses` templates, which all open with 🚨.
    /// They get a red card so they can never pass for an ordinary answer.
    private var isEmergency: Bool {
        message.content.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("🚨")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .background(isEmergency ? ChatPalette.emergencyFill : ChatPalette.accentSoft.opacity(0.45))

            Divider()

            VStack(alignment: .leading, spacing: 18) {
                if message.content.isEmpty {
                    TypingIndicator()
                        .padding(.vertical, 8)
                } else {
                    ReplyBlocksView(
                        content: message.content,
                        isStreaming: isStreaming,
                        // Only on the settled answer: while drafting, the last paragraph keeps
                        // changing and the box would flicker on and off.
                        liftsProviderNote: !isEmergency && !isStreaming
                    )
                    .textSelection(.enabled)
                }

                // Proposals stay inside the card, under the reply, so an offer to remember
                // something reads as part of what the assistant just said.
                if !message.profileUpdateProposals.isEmpty {
                    ProfileUpdateConfirmationCard(
                        updates: message.profileUpdateProposals,
                        onAccept: onAcceptProfileUpdate,
                        onDismiss: onDismissProfileUpdate
                    )
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)

            if !isWriting {
                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    speechButton
                    if !message.sources.isEmpty {
                        CitationsView(
                            sources: message.sources,
                            hasDocument: hasSourceDocument,
                            onOpenDocument: onOpenSourceDocument
                        )
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(cardShape.fill(Color(.secondarySystemGroupedBackground)))
        .clipShape(cardShape)
        .overlay(
            cardShape.strokeBorder(
                isEmergency ? ChatPalette.emergencyText : Color(.separator),
                lineWidth: isEmergency ? 2 : 1
            )
        )
    }

    // MARK: - Header

    /// The writing status sits under the name rather than beside it: sharing one row at large
    /// text sizes squeezed "Trợ lý MobiCure" onto two lines.
    private var header: some View {
        HStack(spacing: 12) {
            avatar

            VStack(alignment: .leading, spacing: 2) {
                Text(isEmergency ? LocalizedStringKey("Khẩn cấp") : LocalizedStringKey("Trợ lý MobiCure"))
                    .appFont(size: 17, weight: .semibold, design: .rounded)
                    .foregroundColor(isEmergency ? ChatPalette.emergencyText : Color(.label))

                if isWriting {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Đang soạn...")
                            .appFont(size: 14, weight: .medium, design: .rounded)
                    }
                    .foregroundColor(ChatPalette.secondaryText)
                }
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// A monogram, not a face or a medical symbol: this is an assistant, and nothing on the card
    /// should suggest a clinician wrote the answer.
    private var avatar: some View {
        Group {
            if isEmergency {
                Image(systemName: "exclamationmark.triangle.fill")
                    .appFont(size: 17, weight: .bold)
                    .foregroundColor(ChatPalette.emergencyText)
            } else {
                Text(verbatim: "M")
                    .appFont(size: 17, weight: .bold, design: .rounded)
                    .foregroundColor(ChatPalette.accentText)
            }
        }
        .frame(width: 38, height: 38)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(isEmergency ? Color(.secondarySystemGroupedBackground) : ChatPalette.accentSoft)
        )
        .accessibilityHidden(true)
    }

    // MARK: - Actions

    /// Read-aloud for patients who would rather listen than read. A filled capsule rather than
    /// text: a bare secondary-label link under the reply read as inert metadata and patients
    /// weren't noticing it. Labelled with what a tap will do — "Dừng đọc" while speaking.
    private var speechButton: some View {
        Button(action: onToggleSpeech) {
            Label {
                Text(isSpeaking ? LocalizedStringKey("Dừng đọc") : LocalizedStringKey("Nghe đọc"))
            } icon: {
                Image(systemName: isSpeaking ? "stop.fill" : "speaker.wave.2.fill")
            }
            .appFont(size: 17, weight: .semibold, design: .rounded)
            .foregroundColor(isSpeaking ? .white : ChatPalette.accentText)
            .padding(.horizontal, 20)
            .frame(minHeight: 48)
            .background(Capsule().fill(isSpeaking ? ChatPalette.accent : ChatPalette.accentSoft))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Answer body

/// The answer text: each `ReplyBlock` with room around it, dividers between consecutive steps,
/// and the closing care-provider note lifted into a caution box.
private struct ReplyBlocksView: View {
    let content: String
    let isStreaming: Bool
    let liftsProviderNote: Bool

    var body: some View {
        let parsed = ReplyBlockParser.parse(content)
        let layout = liftsProviderNote
            ? ReplyBlockParser.separatingProviderNote(from: parsed)
            : (blocks: parsed, note: String?.none)

        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(layout.blocks.enumerated()), id: \.offset) { index, block in
                if index > 0, block.isStep, layout.blocks[index - 1].isStep {
                    Divider()
                }
                // The caret trails the last block, which is where the draft is growing.
                blockView(block, showsCaret: isStreaming && index == layout.blocks.count - 1)
            }

            if let note = layout.note {
                ProviderNote(text: note)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: ReplyBlock, showsCaret: Bool) -> some View {
        switch block {
        case .heading(let text):
            Text(inlineMarkdown: text, showsCaret: showsCaret)
                .appFont(size: 20, weight: .bold, design: .rounded)
                .foregroundColor(Color(.label))
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            Text(inlineMarkdown: text, showsCaret: showsCaret)
                .appFont(size: 18, design: .rounded)
                .foregroundColor(Color(.label))
                .lineSpacing(5)
        case let .step(number, title, text, details):
            StepRow(number: number, title: title, text: text, details: details, showsCaret: showsCaret)
        case .bullets(let items):
            BulletList(items: items, showsCaret: showsCaret)
        }
    }
}

private struct StepRow: View {
    let number: String
    let title: String?
    let text: String?
    let details: [String]
    let showsCaret: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(verbatim: number)
                .appFont(size: 17, weight: .bold, design: .rounded)
                .foregroundColor(ChatPalette.accentText)
                .frame(minWidth: 36, minHeight: 36)
                .background(Circle().fill(ChatPalette.accentSoft))

            VStack(alignment: .leading, spacing: 6) {
                if let title {
                    Text(inlineMarkdown: title, showsCaret: showsCaret && text == nil && details.isEmpty)
                        .appFont(size: 18, weight: .bold, design: .rounded)
                        .foregroundColor(Color(.label))
                }
                if let text {
                    // Under a title the explanation steps back a shade — still well above 4.5:1
                    // in both schemes — so the headline is what the eye lands on.
                    Text(inlineMarkdown: text, showsCaret: showsCaret && details.isEmpty)
                        .appFont(size: 18, design: .rounded)
                        .foregroundColor(title == nil ? Color(.label) : ChatPalette.secondaryText)
                        .lineSpacing(5)
                }
                if !details.isEmpty {
                    BulletList(items: details, showsCaret: showsCaret)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct BulletList: View {
    let items: [String]
    let showsCaret: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(verbatim: "•")
                        .appFont(size: 18, weight: .heavy, design: .rounded)
                        .foregroundColor(ChatPalette.accentText)
                        .accessibilityHidden(true)
                    Text(inlineMarkdown: item, showsCaret: showsCaret && index == items.count - 1)
                        .appFont(size: 18, design: .rounded)
                        .foregroundColor(Color(.label))
                        .lineSpacing(5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// The answer's closing "check with your doctor" paragraph, set apart so it is not a line lost
/// at the bottom of a long reply. Text stays `.label` for legibility; the amber is on the frame.
private struct ProviderNote: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Lưu ý", systemImage: "exclamationmark.circle.fill")
                .appFont(size: 17, weight: .bold, design: .rounded)
                .foregroundColor(ChatPalette.cautionText)

            Text(inlineMarkdown: text)
                .appFont(size: 18, design: .rounded)
                .foregroundColor(Color(.label))
                .lineSpacing(5)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(ChatPalette.cautionFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(ChatPalette.cautionBorder, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Typing Indicator

/// Three pulsing dots shown before the model has written anything — the language, guardrail and
/// retrieval stages that run ahead of generation. Once draft tokens arrive the text itself takes
/// over as the progress cue.
private struct TypingIndicator: View {
    @State private var phase = 0

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .frame(width: 9, height: 9)
                    .foregroundColor(ChatPalette.accentText)
                    .opacity(phase == index ? 1.0 : 0.3)
            }
        }
        .accessibilityHidden(true)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 350_000_000)
                withAnimation(.easeInOut(duration: 0.3)) {
                    phase = (phase + 1) % 3
                }
            }
        }
    }
}

#Preview {
    ScrollView {
        VStack(spacing: 24) {
            AssistantReplyCard(message: ChatMessage(
                role: "assistant",
                content: """
                Sau mổ 12 ngày, bạn có thể theo kế hoạch 3 bước:

                1. **Ăn đủ đạm mỗi bữa:** Cá, trứng, thịt nạc, đậu hũ — đạm giúp mô vết mổ tái tạo.
                2. **Uống 1,5–2 lít nước, chia nhỏ** – uống từng ngụm suốt ngày.
                3. **Tạm tránh:**
                   - đồ chiên rán
                   - rượu bia

                Nếu nôn liên tục hoặc sốt trên 38,5°C, hãy liên hệ bác sĩ ngay.
                """,
                sources: [
                    MedicalSource(id: "1", title: "Hướng dẫn chăm sóc sau mổ đại trực tràng", excerpt: "", page: 12, documentName: "BV K, 2024")
                ]
            ))
            AssistantReplyCard(message: ChatMessage(role: "assistant", content: "Dựa trên tài liệu y tế, các dấu hiệu"), isStreaming: true)
            AssistantReplyCard(message: ChatMessage(role: "assistant", content: ""))
        }
        .padding(16)
    }
}
