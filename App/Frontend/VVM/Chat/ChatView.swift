//
//  ChatView.swift
//  MobiCureVN
//
//  Created by Anh Phung on 4/24/26.
//

import PhotosUI
import SwiftUI
import UIKit

struct ChatView: View {

    @StateObject private var viewModel: ChatViewModel
    // Observe the shared TranslationService so the hint strip and state banner
    // re-render automatically when sessions become ready.
    @ObservedObject private var translationService = AppConfig.translationService
    @FocusState private var inputFocused: Bool
    @State private var scrollProxy: ScrollViewProxy? = nil
    @State private var isShowingHistorySidebar = false
    @State private var isShowingAttachmentSheet = false
    @State private var isShowingCameraPicker = false
    @State private var isShowingPhotoPicker = false
    @State private var photoPickerItems: [PhotosPickerItem] = []
    @State private var attachedImages: [UIImage] = []
    private let imageOnlyDraftText = "Image attached"

    init(llmService: LLMServiceProtocol? = nil) {
        _viewModel = StateObject(wrappedValue: ChatViewModel(llmService: llmService))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Model download progress
                if viewModel.backendStatus == .loading {
                    downloadProgressBanner
                }

                // Language pack download (only shown while packs are being fetched for the first time)
                if translationService.isPreparingLanguagePacks && !translationService.isReady {
                    languagePackDownloadBanner
                }

                // Translation pipeline status (shown when translating input or output)
                if let label = viewModel.processingStateLabel {
                    translationStatusBanner(label: label)
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
        .confirmationDialog("Attach image", isPresented: $isShowingAttachmentSheet, titleVisibility: .visible) {
            Button("Take Photo") {
                isShowingCameraPicker = true
            }
            Button("Upload image") {
                isShowingPhotoPicker = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Choose how to add an image to your message.")
        }
        .photosPicker(
            isPresented: $isShowingPhotoPicker,
            selection: $photoPickerItems,
            maxSelectionCount: 10,
            matching: .images
        )
        .onChange(of: photoPickerItems) { _, newItems in
            guard !newItems.isEmpty else { return }
            Task {
                await loadPickedImages(from: newItems)
            }
        }
        .fullScreenCover(isPresented: $isShowingCameraPicker) {
            CameraImagePicker(image: cameraCaptureBinding)
                .ignoresSafeArea()
        }
        // NOTE: .translationTask modifiers live on HomeView (the persistent TabView container)
        // so the TranslationSession stays valid regardless of which tab is active.
        // Attaching them here caused fatal crashes when ChatView disappeared while a
        // translation was in-flight: "Attempted to use TranslationSession after the view
        // it was attached to has disappeared."
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

    // MARK: - Translation Status Banner

    @ViewBuilder
    private func translationStatusBanner(label: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(0.75)
                .tint(.accentColor)
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color(.secondaryLabel))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(Color(.secondarySystemBackground))
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(.easeInOut(duration: 0.2), value: label)
    }

    // MARK: - Language Pack Download Banner

    private var languagePackDownloadBanner: some View {
        HStack(spacing: 8) {
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(0.75)
                .tint(.accentColor)
            Text("Đang tải gói ngôn ngữ Việt↔Anh... / Downloading Vietnamese↔English language packs...")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Color(.secondaryLabel))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground))
        .transition(.move(edge: .top).combined(with: .opacity))
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
                                MessageBubble(message: ChatMessage(role: item.role, content: item.content, sources: item.sources, imageData: item.imageData))
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
        VStack(spacing: 0) {
            // Language hint strip — only shown when translation sessions are ready
            if translationService.isReady {
                HStack(spacing: 4) {
                    Image(systemName: "globe")
                        .font(.system(size: 10))
                        .foregroundColor(Color(.tertiaryLabel))
                    Text("Hỗ trợ tiếng Việt & English / Supports Vietnamese & English")
                        .font(.system(size: 10))
                        .foregroundColor(Color(.tertiaryLabel))
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
            }

            VStack(spacing: 10) {
                if !attachedImages.isEmpty {
                    attachedImagesPreview(images: attachedImages)
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                }

                HStack(alignment: .bottom, spacing: 10) {
                    Button {
                        isShowingAttachmentSheet = true
                    } label: {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.accentColor)
                            .frame(width: 36, height: 36)
                            .background(
                                Circle().fill(Color.accentColor.opacity(0.12))
                            )
                    }
                    .accessibilityLabel("Attach image")

                    // Text field
                    TextField("Hỏi về quá trình hồi phục... / Ask about recovery...",
                              text: $viewModel.inputText,
                              axis: .vertical)
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
                            submitCurrentMessage()
                        }

                    // Send / Stop button
                    Button {
                        if viewModel.isLoading {
                            viewModel.cancelStreaming()
                        } else {
                            submitCurrentMessage()
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
                        !canSubmitDraft
                    )
                    .animation(.easeInOut(duration: 0.15), value: viewModel.isLoading)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
        .background(Color(.systemBackground))
    }

    private func submitCurrentMessage() {
        guard !viewModel.isLoading else {
            viewModel.cancelStreaming()
            return
        }

        let trimmed = viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = !trimmed.isEmpty ? trimmed : (attachedImages.isEmpty ? "" : imageOnlyDraftText)
        guard !prompt.isEmpty else { return }

        let displayText = trimmed.isEmpty ? "" : trimmed
        viewModel.sendMessage(
            prompt: prompt,
            displayContent: displayText,
            attachedImageData: attachedImages.compactMap { $0.jpegData(compressionQuality: 0.9) }
        )
        clearAttachmentDraft()
    }

    private var canSubmitDraft: Bool {
        viewModel.isLoading || !viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachedImages.isEmpty
    }

    private func clearAttachmentDraft() {
        attachedImages = []
        photoPickerItems = []
        isShowingPhotoPicker = false
        isShowingCameraPicker = false
    }

    private var cameraCaptureBinding: Binding<UIImage?> {
        Binding(
            get: { nil },
            set: { newImage in
                guard let newImage else { return }
                attachedImages.append(newImage)
            }
        )
    }

    private func loadPickedImages(from items: [PhotosPickerItem]) async {
        let loadedImages = await withTaskGroup(of: UIImage?.self, returning: [UIImage].self) { group in
            for item in items {
                group.addTask {
                    guard let data = try? await item.loadTransferable(type: Data.self),
                          let image = UIImage(data: data) else {
                        return nil
                    }
                    return image
                }
            }

            var images: [UIImage] = []
            for await image in group {
                if let image { images.append(image) }
            }
            return images
        }

        await MainActor.run {
            attachedImages.append(contentsOf: loadedImages)
            photoPickerItems = []
        }
    }

    @ViewBuilder
    private func attachedImagesPreview(images: [UIImage]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(images.count == 1 ? "1 image attached" : "\(images.count) images attached")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Add a question to send them with your message.")
                        .font(.system(size: 12))
                        .foregroundColor(Color(.secondaryLabel))
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                Button {
                    attachedImages = []
                    photoPickerItems = []
                    if viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines) == imageOnlyDraftText {
                        viewModel.inputText = ""
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color(.secondaryLabel))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color(.tertiarySystemBackground)))
                }
                .accessibilityLabel("Remove attached images")
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(images.enumerated()), id: \.offset) { index, image in
                        ZStack(alignment: .topTrailing) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 72, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .clipped()

                            Button {
                                attachedImages.remove(at: index)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundColor(.white)
                                    .shadow(radius: 3)
                            }
                            .offset(x: 6, y: -6)
                        }
                    }
                }
                .padding(.trailing, 4)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
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
                        submitCurrentMessage()
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
            clearAttachmentDraft()
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
        .fixedSize()
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
