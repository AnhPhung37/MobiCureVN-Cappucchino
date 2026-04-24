//
//  MessageBubble.swift
//  MobiCureVN
//
//  Created by Anh Phung on 4/24/26.
//

import SwiftUI

struct MessageBubble: View {

    let message: ChatMessage

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isUser { Spacer(minLength: 48) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                // Bubble
                Text(message.content.isEmpty && message.isStreaming ? " " : message.content)
                    .font(.system(size: 16, weight: .regular, design: .rounded))
                    .foregroundColor(isUser ? .white : Color(.label))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(bubbleBackground)
                    .overlay(streamingCursor)

                // Timestamp
                Text(message.timestamp.formatted(.dateTime.hour().minute()))
                    .font(.system(size: 11))
                    .foregroundColor(Color(.secondaryLabel))
                    .padding(.horizontal, 4)
            }

            if !isUser { Spacer(minLength: 48) }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Sub-views

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

    @ViewBuilder
    private var streamingCursor: some View {
        if message.isStreaming {
            HStack {
                Spacer()
                VStack {
                    Spacer()
                    BlinkingCursor()
                        .padding(.trailing, 14)
                        .padding(.bottom, 10)
                }
            }
        }
    }
}

// MARK: - Blinking Cursor

private struct BlinkingCursor: View {
    @State private var visible = true

    var body: some View {
        Rectangle()
            .frame(width: 2, height: 16)
            .foregroundColor(Color(.secondaryLabel))
            .opacity(visible ? 1 : 0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.5).repeatForever()) {
                    visible.toggle()
                }
            }
    }
}

#Preview {
    VStack(spacing: 12) {
        MessageBubble(message: ChatMessage(
            role: .user,
            content: "Vết mổ của tôi có bị nhiễm trùng không?"
        ))
        MessageBubble(message: ChatMessage(
            role: .assistant,
            content: "Dựa trên tài liệu y tế, các dấu hiệu nhiễm trùng vết mổ bao gồm: đỏ, sưng, nóng...",
            isStreaming: true
        ))
    }
    .padding(.vertical)
}
