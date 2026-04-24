//
//  ChatView.swift
//  MobiCureVN
//
//  Created by Anh Phung on 4/24/26.
//

import SwiftUI

struct ChatView: View {

    @StateObject private var viewModel: ChatViewModel
    @FocusState private var inputFocused: Bool
    @State private var scrollProxy: ScrollViewProxy? = nil

    init(llmService: LLMServiceProtocol) {
        _viewModel = StateObject(wrappedValue: ChatViewModel(llmService: llmService))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Message list
                messageList

                Divider()

                // Input bar
                inputBar
            }
            .navigationTitle("MobiCure")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    clearButton
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    statusBadge
                }
            }
        }
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    // Empty state
                    if viewModel.messages.isEmpty {
                        emptyState
                    }

                    // Messages
                    ForEach(viewModel.messages) { message in
                        VStack(alignment: .leading, spacing: 8) {
                            MessageBubble(message: message)

                            // Citations below assistant messages
                            if message.role == .assistant,
                               !message.citations.isEmpty,
                               !message.isStreaming {
                                CitationsView(sources: message.citations)
                                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                            }
                        }
                        .id(message.id)
                        .padding(.vertical, 4)
                    }

                    // Error banner
                    if let error = viewModel.errorMessage {
                        ErrorView(message: error, onDismiss: {
                            viewModel.errorMessage = nil
                        })
                        .padding(.top, 8)
                    }

                    // Bottom anchor for scroll
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .padding(.top, 12)
                .padding(.bottom, 8)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: viewModel.messages.count)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: viewModel.messages.last?.content) { _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onAppear {
                scrollProxy = proxy
            }
        }
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            // Text field
            TextField("Hỏi về quá trình hồi phục...", text: $viewModel.inputText, axis: .vertical)
                .font(.system(size: 16))
                .lineLimit(1...5)
                .focused($inputFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                )
                .onSubmit {
                    viewModel.sendMessage()
                }

            // Send / Stop button
            Button {
                if viewModel.isLoading {
                    viewModel.cancelStreaming()
                } else {
                    viewModel.sendMessage()
                }
            } label: {
                Image(systemName: viewModel.isLoading ? "stop.fill" : "arrow.up")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .background(
                        Circle().fill(
                            viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !viewModel.isLoading
                            ? Color(.tertiaryLabel)
                            : Color.accentColor
                        )
                    )
            }
            .disabled(
                viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !viewModel.isLoading
            )
            .animation(.easeInOut(duration: 0.15), value: viewModel.isLoading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(.systemBackground))
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "cross.case.fill")
                .font(.system(size: 48))
                .foregroundColor(.accentColor.opacity(0.8))
                .padding(.bottom, 4)

            Text("Xin chào!")
                .font(.system(size: 22, weight: .bold, design: .rounded))

            Text("Tôi có thể giúp bạn về quá trình\nhồi phục sau phẫu thuật.")
                .font(.system(size: 15))
                .foregroundColor(Color(.secondaryLabel))
                .multilineTextAlignment(.center)

            // Suggestion chips
            VStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button {
                        viewModel.inputText = suggestion
                        viewModel.sendMessage()
                    } label: {
                        Text(suggestion)
                            .font(.system(size: 14))
                            .foregroundColor(.accentColor)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .strokeBorder(Color.accentColor.opacity(0.4), lineWidth: 1)
                                    .background(
                                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                                            .fill(Color.accentColor.opacity(0.06))
                                    )
                            )
                    }
                }
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.top, 60)
    }

    // MARK: - Toolbar Items

    private var clearButton: some View {
        Button {
            viewModel.clearConversation()
        } label: {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 16))
        }
        .disabled(viewModel.messages.isEmpty)
    }

    private var statusBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .frame(width: 7, height: 7)
                .foregroundColor(viewModel.isLoading ? .orange : .green)
                .animation(.easeInOut(duration: 0.3), value: viewModel.isLoading)
            Text(viewModel.isLoading ? "Đang trả lời..." : "Sẵn sàng")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color(.secondaryLabel))
        }
    }

    // MARK: - Suggestion Chips Data

    private let suggestions = [
        "Vết mổ của tôi có bình thường không?",
        "Tôi nên ăn gì sau phẫu thuật?",
        "Cơn đau bao lâu thì hết?"
    ]
}

// MARK: - Error Banner

private struct ErrorView: View {
    let message: String
    let onDismiss: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            
            Text(message)
                .font(.system(size: 14))
                .foregroundColor(Color(.label))
            
            Spacer()
            
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(Color(.secondaryLabel))
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.orange.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.orange.opacity(0.3), lineWidth: 1)
                )
        )
        .padding(.horizontal, 16)
    }
}

#Preview {
    ChatView(llmService: MockLLMService())
}
