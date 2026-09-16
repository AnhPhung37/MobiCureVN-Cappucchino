//
//  MessageBubble.swift
//  MobiCureVN
//
//  Created by Anh Phung on 4/24/26.
//

import UIKit
import SwiftUI

struct MessageBubble: View {

    let message: ChatMessage
    var onAcceptProfileUpdate: (ProposedProfileUpdate) -> Void = { _ in }
    var onDismissProfileUpdate: (ProposedProfileUpdate) -> Void = { _ in }
    /// True while this bubble is showing draft text the model is still writing. The text is raw
    /// decoder output that no guardrail has validated yet and will be replaced wholesale by the
    /// final answer, so it is marked as in progress rather than presented as a finished reply.
    var isStreaming: Bool = false
    /// True while this specific message is being read aloud — at most one bubble at a time.
    var isSpeaking: Bool = false
    var onToggleSpeech: () -> Void = {}
    /// Whether a citation's source PDF is bundled, and what to do when its card is tapped.
    var hasSourceDocument: (MedicalSource) -> Bool = { _ in false }
    var onOpenSourceDocument: (MedicalSource) -> Void = { _ in }

    private var isUser: Bool { message.role.lowercased() == "user" }

    var body: some View {
        if isUser {
            userBubble
        } else {
            AssistantReplyCard(
                message: message,
                isStreaming: isStreaming,
                isSpeaking: isSpeaking,
                onToggleSpeech: onToggleSpeech,
                hasSourceDocument: hasSourceDocument,
                onOpenSourceDocument: onOpenSourceDocument,
                onAcceptProfileUpdate: onAcceptProfileUpdate,
                onDismissProfileUpdate: onDismissProfileUpdate
            )
        }
    }

    /// The patient's own message, right-aligned. A neutral fill rather than the accent: the reply
    /// card carries the colour, and 18pt dark-on-light text reads more easily than white on a
    /// saturated blue.
    private var userBubble: some View {
        HStack {
            Spacer(minLength: 40)

            VStack(alignment: .leading, spacing: 10) {
                attachedImagesView

                if !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(inlineMarkdown: message.content)
                        .appFont(size: 18, design: .rounded)
                        .foregroundColor(Color(.label))
                        .lineSpacing(5)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
        }
    }

    @ViewBuilder
    private var attachedImagesView: some View {
        if !message.imageData.isEmpty {
            let images = message.imageData.compactMap { UIImage(data: $0) }

            if images.count == 1, let image = images.first {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: 240, maxHeight: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .clipped()
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 120, height: 120)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .clipped()
                        }
                    }
                }
                .frame(maxWidth: 280, alignment: .leading)
            }
        }
    }
}

extension Text {
    /// `content` rendered as inline Markdown, optionally followed by a caret marking text the
    /// model is still writing.
    ///
    /// Draft text arrives mid-sentence, so its Markdown is routinely unbalanced (`**bold` with no
    /// closing pair) — `AttributedString` renders those markers literally instead of failing, and
    /// the final answer re-renders cleanly once it replaces the draft.
    ///
    /// A `Text` rather than `some View` so the caret can be concatenated inline: it has to sit at
    /// the end of the last line and flow with it, which an adjacent view cannot do.
    init(inlineMarkdown content: String, showsCaret: Bool = false) {
        let rendered: Text
        if let attributed = try? AttributedString(markdown: content, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            rendered = Text(attributed)
        } else {
            rendered = Text(verbatim: content)
        }
        self = showsCaret ? rendered + Text(verbatim: " ▌").foregroundStyle(Color(.tertiaryLabel)) : rendered
    }
}

#Preview {
    VStack(spacing: 24) {
        MessageBubble(message: ChatMessage(
            role: "user",
            content: "Vết mổ của tôi có bị nhiễm trùng không?"
        ))
        MessageBubble(message: ChatMessage(
            role: "assistant",
            content: "Dựa trên tài liệu y tế, các dấu hiệu nhiễm trùng vết mổ bao gồm: đỏ, sưng, nóng..."
        ))
        MessageBubble(
            message: ChatMessage(role: "assistant", content: "Dựa trên tài liệu y tế, các dấu hiệu nhiễm"),
            isStreaming: true
        )
    }
    .padding(16)
}
