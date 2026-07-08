//
//  MessageBubble.swift
//  MobiCureVN
//
//  Created by Anh Phung on 4/24/26.
//

import SwiftUI

struct MessageBubble: View {

    let message: ChatMessage

    private var isUser: Bool { message.role.lowercased() == "user" }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isUser { Spacer(minLength: 48) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                // Bubble — while an assistant reply is still empty, show a typing indicator.
                // Responses are buffered (validated by the output guardrail before display),
                // so without this the bubble would sit blank for the whole generation.
                Group {
                    if !isUser && message.content.isEmpty {
                        TypingIndicator()
                    } else {
                        markdownText(message.content)
                            .font(.system(size: 16, weight: .regular, design: .rounded))
                            .foregroundColor(isUser ? .white : Color(.label))
                            .textSelection(.enabled)
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

    @ViewBuilder
    private func markdownText(_ content: String) -> some View {
        if let attributed = try? AttributedString(markdown: content, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            Text(attributed)
        } else {
            Text(content)
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

/// Three pulsing dots shown inside an assistant bubble while its reply is still being
/// generated (responses are buffered, so the bubble would otherwise sit empty).
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
    }
    .padding(.vertical)
}
