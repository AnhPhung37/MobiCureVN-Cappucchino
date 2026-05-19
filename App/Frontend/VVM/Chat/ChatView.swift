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
    @State private var isShowingHistorySidebar = false

    init(llmService: LLMServiceProtocol) {
        _viewModel = StateObject(wrappedValue: ChatViewModel(llmService: llmService))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Model download progress
                if viewModel.backendStatus == .loading {
                    downloadProgressBanner
                }

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
                    HStack(spacing: 14) {
                        historyButton
                        newChatButton
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    statusBadge
                }
            }
            .overlay(alignment: .trailing) {
                if isShowingHistorySidebar {
                    historySidebar
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
    }

    // MARK: - History Sidebar

    private var historySidebar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .trailing) {
                Color.black.opacity(0.22)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isShowingHistorySidebar = false
                        }
                    }

                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Chat History")
                                .font(.headline)
                            Text("Grouped by time")
                                .font(.caption)
                                .foregroundColor(Color(.secondaryLabel))
                        }
                        Spacer()
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isShowingHistorySidebar = false
                            }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(Color(.secondaryLabel))
                                .frame(width: 30, height: 30)
                                .background(Circle().fill(Color(.tertiarySystemBackground)))
                        }
                    }

                    ScrollView {
                        if viewModel.conversationSections.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("No chat history yet.")
                                    .font(.system(size: 15, weight: .semibold))
                                Text("Start a chat and your saved messages will show here.")
                                    .font(.system(size: 13))
                                    .foregroundColor(Color(.secondaryLabel))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(Color(.secondarySystemBackground))
                            )
                        } else {
                            LazyVStack(spacing: 12) {
                                ForEach(viewModel.conversationSections) { section in
                                    VStack(alignment: .leading, spacing: 10) {
                                        Text(section.title)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundColor(Color(.label))

                                        ForEach(section.items) { conversation in
                                            HStack(alignment: .top, spacing: 10) {
                                                Button {
                                                    Task {
                                                        await viewModel.loadConversation(conversation.id)
                                                    }
                                                    withAnimation(.easeInOut(duration: 0.2)) {
                                                        isShowingHistorySidebar = false
                                                    }
                                                } label: {
                                                    VStack(alignment: .leading, spacing: 4) {
                                                        Text(conversation.title.isEmpty ? "Chat" : conversation.title)
                                                            .font(.system(size: 14, weight: .semibold))
                                                            .foregroundColor(Color(.label))
                                                            .lineLimit(1)
                                                        Text(conversation.preview.isEmpty ? "No preview" : conversation.preview)
                                                            .font(.system(size: 13))
                                                            .foregroundColor(Color(.secondaryLabel))
                                                            .lineLimit(2)
                                                    }
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                                    .padding(12)
                                                    .background(
                                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                            .fill(viewModel.currentConversationId == conversation.id ? Color.accentColor.opacity(0.12) : Color(.systemBackground))
                                                            .overlay(
                                                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                                    .strokeBorder(viewModel.currentConversationId == conversation.id ? Color.accentColor.opacity(0.35) : Color.clear, lineWidth: 1)
                                                            )
                                                    )
                                                }
                                                .buttonStyle(.plain)

                                                Button {
                                                    Task {
                                                        await viewModel.deleteConversation(conversation.id)
                                                    }
                                                } label: {
                                                    Image(systemName: "trash")
                                                        .font(.system(size: 14, weight: .semibold))
                                                        .foregroundColor(.red)
                                                        .frame(width: 34, height: 34)
                                                        .background(Circle().fill(Color.red.opacity(0.12)))
                                                }
                                                .buttonStyle(.plain)
                                            }
                                        }
                                    }
                                    .padding(14)
                                    .background(
                                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                                            .fill(Color(.secondarySystemBackground))
                                    )
                                }
                            }
                        }
                    }
                    .scrollIndicators(.hidden)

                    Spacer(minLength: 0)
                }
                .padding(16)
                .frame(width: min(geometry.size.width * 0.84, 360), height: geometry.size.height)
                .background(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(Color(.systemBackground))
                        .shadow(color: Color.black.opacity(0.18), radius: 20, x: -4, y: 0)
                )
                .offset(x: isShowingHistorySidebar ? 0 : min(geometry.size.width * 0.84, 360))
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Download Progress Banner

    private var downloadProgressBanner: some View {
        let percent = Int((viewModel.downloadProgress * 100).rounded())
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle")
                    .foregroundColor(.accentColor)
                Text("Đang tải model...")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Text("\(percent)%")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(.secondaryLabel))
                    .monospacedDigit()
            }
            ProgressView(value: viewModel.downloadProgress)
                .progressViewStyle(.linear)
                .animation(.easeInOut(duration: 0.25), value: viewModel.downloadProgress)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground))
        .transition(.move(edge: .top).combined(with: .opacity))
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

                    // Messages grouped by sections
                    ForEach(viewModel.sections) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(section.title)
                                .font(.footnote)
                                .foregroundColor(Color(.secondaryLabel))
                                .padding(.horizontal, 16)
                                .padding(.top, 8)
                            ForEach(section.items) { item in
                                MessageBubble(message: ChatMessage(role: item.role, content: item.content, sources: item.sources))
                                    .padding(.vertical, 4)
                            }
                        }
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
            .onChange(of: viewModel.messages.last?.content) { _, _ in
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

    private var historyButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                isShowingHistorySidebar.toggle()
            }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 16))
        }
        .accessibilityLabel("Chat history")
    }

    private var newChatButton: some View {
        Button {
            viewModel.clearConversation()
            withAnimation(.easeInOut(duration: 0.2)) {
                isShowingHistorySidebar = false
            }
        } label: {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 16))
        }
        .accessibilityLabel("New chat")
        .disabled(viewModel.messages.isEmpty)
    }

    private func formatConversationDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private var statusBadge: some View {
        let status = viewModel.backendStatus
        return HStack(spacing: 4) {
            Circle()
                .frame(width: 7, height: 7)
                .foregroundColor(statusColor(for: status))
                .animation(.easeInOut(duration: 0.3), value: status)
            Text(statusLabel(for: status))
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color(.secondaryLabel))
                .lineLimit(1)
        }
        .fixedSize() // ← move fixedSize here, to the HStack level
    }

    private func statusLabel(for status: LLMBackendStatus) -> String {
        switch status {
        case .mock:
            return "Mock service"
        case .mockWithDownloadedModel:
            return "Mock + model downloaded"
        case .loading:
            return "Đang tải model..."
        case .localModelReady:
            return "Model cục bộ"
        case .unavailable:
            return "Model không sẵn sàng"
        }
    }

    private func statusColor(for status: LLMBackendStatus) -> Color {
        switch status {
        case .mock:
            return .blue
        case .mockWithDownloadedModel:
            return .cyan
        case .loading:
            return .orange
        case .localModelReady:
            return .green
        case .unavailable:
            return .red
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
