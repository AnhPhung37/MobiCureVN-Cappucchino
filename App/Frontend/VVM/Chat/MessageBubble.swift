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
    /// final answer, so it is marked with a caret rather than presented as a finished reply.
    var isStreaming: Bool = false

    private var isUser: Bool { message.role.lowercased() == "user" }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isUser { Spacer(minLength: 48) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                // Bubble — until the first draft tokens arrive there is nothing to show, so an
                // empty assistant reply gets the typing indicator. That gap covers the language
                // and retrieval stages, which run before the model writes anything.
                Group {
                    if isUser {
                        VStack(alignment: .leading, spacing: 10) {
                            attachedImagesView

                            if !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                markdownText(message.content)
                                    .appFont(size: 16, weight: .regular, design: .rounded)
                                    .foregroundColor(.white)
                                    .textSelection(.enabled)
                            }
                        }
                    } else if message.content.isEmpty {
                        TypingIndicator()
                    } else {
                        // Proposals live INSIDE the bubble, under the reply text, so an offer to
                        // remember something reads as part of what the assistant just said
                        // rather than as a separate widget parked underneath it.
                        VStack(alignment: .leading, spacing: 0) {
                            markdownText(message.content, showsCaret: isStreaming)
                                .appFont(size: 16, weight: .regular, design: .rounded)
                                .foregroundColor(Color(.label))
                                .textSelection(.enabled)

                            if !message.profileUpdateProposals.isEmpty {
                                ProfileUpdateConfirmationCard(
                                    updates: message.profileUpdateProposals,
                                    onAccept: onAcceptProfileUpdate,
                                    onDismiss: onDismissProfileUpdate
                                )
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(bubbleBackground)

                if !isUser && !message.sources.isEmpty {
                    CitationsView(sources: message.sources)
                }
            }

            if !isUser { Spacer(minLength: 48) }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Sub-views

    /// Renders `content` as inline markdown. Draft text arrives mid-sentence, so its markdown is
    /// routinely unbalanced (`**bold` with no closing pair) — `AttributedString` renders those
    /// markers literally instead of failing, and the final answer re-renders cleanly once it
    /// replaces the draft.
    ///
    /// Returns `Text` rather than `some View` so the caret can be concatenated inline: it has to
    /// sit at the end of the last line and flow with it, which an adjacent view cannot do.
    private func markdownText(_ content: String, showsCaret: Bool = false) -> Text {
        let rendered: Text
        if let attributed = try? AttributedString(markdown: content, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            rendered = Text(attributed)
        } else {
            rendered = Text(content)
        }
        guard showsCaret else { return rendered }
        return rendered + Text(" ▌").foregroundStyle(Color(.tertiaryLabel))
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

    @ViewBuilder
    private var bubbleBackground: some View {
        if isUser {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.accentColor)
        } else {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        }
    }
}

// MARK: - Typing Indicator

/// Three pulsing dots shown inside an assistant bubble before the model has written anything —
/// the language, guardrail and retrieval stages that run ahead of generation. Once draft tokens
/// start arriving the text itself takes over as the progress cue.
private struct TypingIndicator: View {
    @State private var phase = 0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .frame(width: 6, height: 6)
                    .foregroundColor(Color(.secondaryLabel))
                    .opacity(phase == index ? 1.0 : 0.3)
            }
        }
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
    VStack(spacing: 12) {
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
    .padding(.vertical)
}
