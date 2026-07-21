import PhotosUI
import SwiftUI
import UIKit

struct ChatWorkspaceView: View {
    @StateObject private var viewModel: ChatViewModel

    @FocusState private var inputFocused: Bool
    @AppStorage(AppearanceMode.storageKey) private var appearanceModeRaw = AppearanceMode.light.rawValue
    @AppStorage(AppLanguage.storageKey) private var appLanguageRaw = AppLanguage.vietnamese.rawValue
    @AppStorage(AppConfig.selectedModelStorageKey) private var selectedModelRaw = ModelCatalog.default.rawValue
    @State private var isSidebarVisible = true
    @State private var isShowingAttachmentSheet = false
    @State private var isShowingCameraPicker = false
    @State private var isShowingPhotoPicker = false
    @State private var photoPickerItems: [PhotosPickerItem] = []
    @State private var attachedImages: [UIImage] = []
    @State private var searchText: String = ""
    @State private var downloadedModels: Set<ModelCatalog> = []

    init(llmService: LLMServiceProtocol? = nil) {
        _viewModel = StateObject(wrappedValue: ChatViewModel(llmService: llmService))
    }

    var body: some View {
        GeometryReader { geometry in
            let isCompact = geometry.size.width < 920
            let sidebarW = isCompact ? 0 : min(max(geometry.size.width * 0.25, 280), 360)
            let overlaySidebarW = min(max(geometry.size.width * 0.80, 280), 340)

            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    if !isCompact {
                        sidebar(width: sidebarW)
                    }

                    mainPanel(isCompact: isCompact)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if isCompact && isSidebarVisible {
                    Color.black.opacity(0.22)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isSidebarVisible = false
                            }
                        }

                    sidebar(width: overlaySidebarW)
                        .frame(maxHeight: .infinity)
                        .shadow(color: Color.black.opacity(0.18), radius: 20, x: 4, y: 0)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .background(workspaceBackground)
            // A status change to ready/unavailable means a download just finished (or
            // failed) — re-scan disk so the picker's "downloaded" badges stay accurate.
            .onChange(of: viewModel.backendStatus) { _, _ in
                refreshDownloadedModels()
            }
            .photosPicker(isPresented: $isShowingPhotoPicker, selection: $photoPickerItems, maxSelectionCount: 10, matching: .images)
            .onChange(of: photoPickerItems) { _, newItems in
                guard !newItems.isEmpty else { return }
                Task { await loadPickedImages(from: newItems) }
            }
            .fullScreenCover(isPresented: $isShowingCameraPicker) {
                CameraImagePicker(image: cameraCaptureBinding)
                    .ignoresSafeArea()
            }
            .confirmationDialog("Attach image", isPresented: $isShowingAttachmentSheet, titleVisibility: .visible) {
                Button("Take Photo") { isShowingCameraPicker = true }
                Button("Upload image") { isShowingPhotoPicker = true }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Choose how to add an image to your message.")
            }
        }
    }

    // MARK: - Sidebar

    private func sidebar(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            sidebarHeader
                .padding(16)

            Divider().opacity(0.6)

            sidebarActions
                .padding(.horizontal, 16)
                .padding(.top, 12)

            newChatButton
                .padding(.horizontal, 16)
                .padding(.top, 14)


            recentChats
                .padding(.horizontal, 12)
                .padding(.top, 12)

            Spacer(minLength: 0)

            emergencyFooter
                .padding(16)
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .background(Color(.systemBackground))
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color(.separator)).frame(width: 1)
        }
    }

    private var sidebarHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.blue)
                    .frame(width: 46, height: 46)
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("MobiCure VN")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                Text("v2.4 · Ngoại tuyến")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(.secondaryLabel))
            }

            Spacer()
        }
    }

    private var sidebarActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusRow(icon: "checkmark.circle.fill", text: "Chạy cục bộ", color: .green)
            statusRow(icon: "wifi.slash", text: "Không cần Internet", color: .green)
            statusRow(icon: "lock.shield.fill", text: "Dữ liệu không rời khỏi thiết bị này", color: .green)
        }
        .font(.system(size: 13, weight: .medium))
    }

    private func statusRow(icon: String, text: LocalizedStringKey, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(color)
            Text(text)
                .foregroundColor(color)
            Spacer(minLength: 0)
        }
    }

    private var newChatButton: some View {
        Button {
            viewModel.clearConversation()
            clearDraftAttachments()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                Text("Cuộc trò chuyện mới")
                    .fontWeight(.semibold)
                Spacer()
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.blue)
            )
        }
    }

   

    private var recentChats: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                Text("CUỘC TRÒ CHUYỆN GẦN ĐÂY")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(Color(.secondaryLabel))
                    .textCase(.uppercase)
                    .padding(.horizontal, 8)

                if viewModel.conversationSections.isEmpty {
                    Text("Chưa có cuộc trò chuyện nào.")
                        .font(.system(size: 13))
                        .foregroundColor(Color(.secondaryLabel))
                        .padding(.horizontal, 8)
                } else {
                    ForEach(filteredConversationSections) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(LocalizedStringKey(section.title))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(Color(.secondaryLabel))
                                .padding(.horizontal, 8)

                            ForEach(section.items) { conversation in
                                Button {
                                    Task { await viewModel.loadConversation(conversation.id) }
                                } label: {
                                    HStack(alignment: .center, spacing: 12) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(conversation.title.isEmpty ? "Chat" : conversation.title)
                                                .font(.system(size: 14, weight: .semibold))
                                                .foregroundColor(Color(.label))
                                                .lineLimit(1)
                                            (conversation.preview.isEmpty ? Text("No preview") : Text(conversation.preview))
                                                .font(.system(size: 12))
                                                .foregroundColor(Color(.secondaryLabel))
                                                .lineLimit(2)
                                        }
                                        Spacer(minLength: 6)
                                        VStack(alignment: .trailing, spacing: 4) {
                                            Text(relativeDate(conversation.lastMessageDate))
                                                .font(.system(size: 11, weight: .medium))
                                                .foregroundColor(Color(.secondaryLabel))
                                            if viewModel.currentConversationId == conversation.id {
                                                Text("Đang mở")
                                                    .font(.system(size: 10, weight: .semibold))
                                                    .padding(.horizontal, 8)
                                                    .padding(.vertical, 4)
                                                    .background(Capsule().fill(Color.blue.opacity(0.12)))
                                                    .foregroundColor(.blue)
                                            }
                                        }
                                    }
                                    .padding(12)
                                    .background(
                                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                                            .fill(viewModel.currentConversationId == conversation.id ? Color.blue.opacity(0.10) : Color(.systemBackground))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                                    .strokeBorder(viewModel.currentConversationId == conversation.id ? Color.blue.opacity(0.22) : Color(.separator).opacity(0.5), lineWidth: 1)
                                            )
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var emergencyFooter: some View {
        HStack(spacing: 8) {
            Image(systemName: "phone.fill")
                .foregroundColor(.red)
            Text("Khẩn cấp: gọi 115 hoặc liên hệ bác sĩ.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color(.secondaryLabel))
            Spacer(minLength: 0)
        }
    }

    // MARK: - Main Panel

    private func mainPanel(isCompact: Bool) -> some View {
        VStack(spacing: 0) {
            topBar(isCompact: isCompact)
                .padding(.horizontal, isCompact ? 16 : 20)
                .padding(.top, 16)
                .padding(.bottom, 12)
                .background(Color(.systemBackground).opacity(0.95))

            Divider().opacity(0.6)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 18) {
                        workspaceHeader

                        if viewModel.backendStatus == .loading && viewModel.isFirstTimeModelSetup {
                            firstTimeModelSetupNotice
                        }

                        if viewModel.messages.isEmpty {
                            emptyHero
                            quickQuestionSection
                        } else {
                            messageThread
                        }

                        if let error = viewModel.errorMessage {
                            ErrorView(message: error, onDismiss: { viewModel.errorMessage = nil })
                                .padding(.horizontal, 16)
                        }

                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, isCompact ? 12 : 20)
                    .padding(.top, 18)
                    .padding(.bottom, 16)
                }
                .onChange(of: viewModel.messages.last?.content) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                .onAppear {
                    // no-op; keep proxy in sync for future scrolling use
                    _ = proxy
                }
            }

            composerBar
                .padding(.horizontal, isCompact ? 10 : 16)
                .padding(.top, 10)
                .padding(.bottom, 12)
                .background(Color(.systemBackground))
        }
        .background(workspaceBackground)
    }

    private func topBar(isCompact: Bool) -> some View {
        HStack(spacing: 12) {
            if isCompact {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isSidebarVisible.toggle()
                    }
                } label: {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Color(.secondaryLabel))
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Color(.secondarySystemBackground)))
                }
            }

            Spacer()

            HStack(spacing: 8) {
                modelPicker
                languageToggle
                Button {
                    cycleAppearanceMode()
                } label: {
                    Image(systemName: appearanceMode.iconName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Color(.secondaryLabel))
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color(.tertiarySystemBackground)))
                }
                .accessibilityLabel("Toggle appearance")
            }
        }
    }

    private func cycleAppearanceMode() {
        appearanceModeRaw = appearanceMode.next.rawValue
    }

    private var appearanceMode: AppearanceMode {
        AppearanceMode(rawValue: appearanceModeRaw) ?? .light
    }

    private var appLanguage: AppLanguage {
        AppLanguage(rawValue: appLanguageRaw) ?? .vietnamese
    }

    private var selectedModel: ModelCatalog {
        ModelCatalog(rawValue: selectedModelRaw) ?? .default
    }

    private var modelPicker: some View {
        Menu {
            Section("Mô hình AI") {
                ForEach(ModelCatalog.allCases, id: \.self) { model in
                    Button {
                        switchModel(to: model)
                    } label: {
                        if model == selectedModel {
                            Label(model.displayName, systemImage: "checkmark")
                        } else {
                            Text(verbatim: model.displayName)
                        }
                        // Second Text renders as the menu item's subtitle: tells the
                        // user whether selecting is instant or a multi-GB download.
                        if downloadedModels.contains(model) {
                            Text("Đã có trên máy · chuyển nhanh")
                        } else {
                            Text("Cần tải về (\(model.approxDownloadSize))")
                        }
                    }
                }
            }
            .onAppear { refreshDownloadedModels() }
        } label: {
            // Show the active model's name inline so the user doesn't have to
            // open the menu just to check which model is in use.
            HStack(spacing: 6) {
                Image(systemName: "cpu")
                    .font(.system(size: 14, weight: .semibold))
                Text(verbatim: selectedModel.shortName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundColor(Color(.secondaryLabel))
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(Capsule().fill(Color(.tertiarySystemBackground)))
        }
        // Switching mid-download or mid-generation would race the in-flight task
        // against the swap; block it until the current one settles.
        .disabled(viewModel.backendStatus == .loading || viewModel.isLoading)
        .accessibilityLabel("Chọn mô hình AI")
    }

    private func switchModel(to model: ModelCatalog) {
        guard model != selectedModel || viewModel.backendStatus == .unavailable else { return }
        Task { await AppConfig.switchModel(to: model) }
    }

    /// Scans Application Support off the main thread for models already on disk.
    /// Runs when the picker opens and after each download finishes.
    private func refreshDownloadedModels() {
        Task.detached(priority: .utility) {
            let downloaded = Set(ModelCatalog.allCases.filter {
                ModelManager.shared.isModelDownloaded(repoID: $0.repoID)
            })
            await MainActor.run { downloadedModels = downloaded }
        }
    }

    private var languageToggle: some View {
        HStack(spacing: 0) {
            languageButton("VI", language: .vietnamese)
            languageButton("EN", language: .english)
        }
        .background(Capsule().fill(Color(.secondarySystemBackground)))
    }

    private func languageButton(_ label: String, language: AppLanguage) -> some View {
        let isSelected = appLanguage == language
        return Button {
            appLanguageRaw = language.rawValue
        } label: {
            Text(verbatim: label)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(isSelected ? .white : Color(.secondaryLabel))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(isSelected ? Capsule().fill(Color.blue) : nil)
        }
    }

    private func tagPill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule().fill(color.opacity(0.08))
            )
            .overlay(
                Capsule().strokeBorder(color.opacity(0.18), lineWidth: 1)
            )
    }

    private var workspaceHeader: some View {
        HStack(alignment: .top, spacing: 16) {
            // VStack(alignment: .leading, spacing: 6) {
            //     // Text(viewModel.currentConversationId == UUID() ? "Cuộc trò chuyện mới" : currentTitle)
            //     //     .font(.system(size: 28, weight: .bold, design: .rounded))
            //     Text("Trợ lý Phục hồi Đại trực tràng")
            //         .font(.system(size: 15, weight: .medium))
            //         .foregroundColor(Color(.secondaryLabel))
            // }

            Spacer()

            HStack(spacing: 10) {
                statusChip
                Button(action: {}) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Color(.secondaryLabel))
                        .frame(width: 42, height: 42)
                        .background(Circle().fill(Color(.secondarySystemBackground)))
                }
            }
        }
    }

    private var currentTitle: String {
        viewModel.conversationSections.first?.items.first?.title.isEmpty == false
        ? (viewModel.conversationSections.first?.items.first?.title ?? "Cuộc trò chuyện")
        : "Cuộc trò chuyện mới"
    }

    private var statusChip: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor(for: viewModel.backendStatus))
                .frame(width: 8, height: 8)
            Text(LocalizedStringKey(statusLabel(for: viewModel.backendStatus)))
                .font(.system(size: 13, weight: .semibold))
            if viewModel.backendStatus == .loading, viewModel.downloadProgress > 0 {
                Text(verbatim: "\(Int(viewModel.downloadProgress * 100))%")
                    .font(.system(size: 13, weight: .semibold))
            }
        }
        .foregroundColor(Color(.secondaryLabel))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            Capsule().fill(Color.green.opacity(0.10))
        )
        .overlay(
            Capsule().strokeBorder(Color.green.opacity(0.18), lineWidth: 1)
        )
    }

    private var firstTimeModelSetupNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.accentColor)
            Text(LocalizedStringKey("Lần đầu tải model có thể mất vài phút, tuỳ theo tốc độ mạng và thiết bị. Các lần sau sẽ nhanh hơn nhiều."))
                .font(.system(size: 12))
                .foregroundColor(Color(.secondaryLabel))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.08))
        )
        .transition(.opacity)
    }

    private var emptyHero: some View {
        VStack(spacing: 16) {
            Text("Hỗ trợ phục hồi sau phẫu thuật ung thư đại trực tràng")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .multilineTextAlignment(.center)
                .foregroundColor(Color(.label))
                .padding(.top, 4)

            HStack(spacing: 16) {
                infoChip(text: "Chạy cục bộ")
                infoChip(text: "Không cần Internet")
                infoChip(text: "Dữ liệu không rời khỏi thiết bị này")
            }
            .foregroundColor(.green)
            .font(.system(size: 13, weight: .semibold))
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
    }

    private func infoChip(text: LocalizedStringKey) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
            Text(text)
        }
    }

    private var quickQuestionSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("CÂU HỎI THƯỜNG GẶP")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(Color(.secondaryLabel))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 10)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                ForEach(quickQuestions) { question in
                    Button {
                        // Resolve the prompt in the selected UI language so the question
                        // sent to the model matches what the user sees on the card.
                        viewModel.inputText = question.prompt.localized(for: appLanguage)
                        submitCurrentMessage()
                    } label: {
                        quickQuestionCard(question)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.top, 4)
    }

    private func quickQuestionCard(_ question: QuickQuestion) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.12))
                        .frame(width: 38, height: 38)
                    Image(systemName: question.icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.blue)
                }
                Spacer()
            }

            Text(LocalizedStringKey(question.title))
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundColor(Color(.label))
            Text(LocalizedStringKey(question.prompt))
                .font(.system(size: 13))
                .foregroundColor(Color(.secondaryLabel))
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 140, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(.systemBackground))
                .shadow(color: Color.black.opacity(0.07), radius: 12, x: 0, y: 4)
        )
    }

    private var messageThread: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(viewModel.sections) { section in
                VStack(alignment: .leading, spacing: 8) {
                    Text(LocalizedStringKey(section.title))
                        .textCase(.uppercase)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(Color(.secondaryLabel))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 8)
                    ForEach(section.items) { item in
                        MessageBubble(message: ChatMessage(role: item.role, content: item.content, sources: item.sources, imageData: item.imageData))
                    }
                }
            }
        }
    }

    private var composerBar: some View {
        VStack(spacing: 10) {
            if !attachedImages.isEmpty {
                attachedImagesPreview(images: attachedImages)
            }

            HStack(alignment: .center, spacing: 12) {
                Button {
                    isShowingAttachmentSheet = true
                } label: {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Color(.secondaryLabel))
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Color(.secondarySystemBackground)))
                }
                .accessibilityLabel("Attach image")

                TextField("Mô tả triệu chứng hoặc đặt câu hỏi...", text: $viewModel.inputText, axis: .vertical)
                    .font(.system(size: 16))
                    .lineLimit(1...5)
                    .focused($inputFocused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(Color(.secondarySystemBackground))
                    )
                    .onSubmit { submitCurrentMessage() }

                Button {
                    if viewModel.isLoading {
                        viewModel.cancelStreaming()
                    } else {
                        submitCurrentMessage()
                    }
                } label: {
                    Image(systemName: viewModel.isLoading ? "stop.fill" : "paperplane.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(viewModel.isLoading || canSubmitDraft ? Color.blue : Color(.tertiaryLabel)))
                }
                .disabled(!canSubmitDraft)
            }

            HStack {
                Text("MobiCure AI cung cấp hỗ trợ lâm sàng, không thay thế tư vấn y tế chuyên nghiệp.")
                    .font(.system(size: 12))
                    .foregroundColor(Color(.secondaryLabel))
                Spacer()
                Image(systemName: "questionmark.circle.fill")
                    .foregroundColor(Color(.secondaryLabel))
            }
            .padding(.horizontal, 6)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color(.systemBackground))
                .shadow(color: Color.black.opacity(0.10), radius: 16, x: 0, y: 6)
        )
    }

    // MARK: - Attachment Helpers

    private var cameraCaptureBinding: Binding<UIImage?> {
        Binding(
            get: { nil },
            set: { newImage in
                guard let newImage else { return }
                attachedImages.append(newImage)
            }
        )
    }

    private func clearDraftAttachments() {
        attachedImages = []
        photoPickerItems = []
        isShowingPhotoPicker = false
        isShowingCameraPicker = false
    }

    private func submitCurrentMessage() {
        guard !viewModel.isLoading else {
            viewModel.cancelStreaming()
            return
        }

        let trimmed = viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = !trimmed.isEmpty ? trimmed : (attachedImages.isEmpty ? "" : "Image attached")
        guard !prompt.isEmpty else { return }

        viewModel.sendMessage(
            prompt: prompt,
            displayContent: trimmed,
            attachedImageData: attachedImages.compactMap { $0.attachmentJPEGData() }
        )
        clearDraftAttachments()
    }

    private var canSubmitDraft: Bool {
        viewModel.isLoading || !viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachedImages.isEmpty
    }

    private func loadPickedImages(from items: [PhotosPickerItem]) async {
        let loaded = await withTaskGroup(of: UIImage?.self, returning: [UIImage].self) { group in
            for item in items {
                group.addTask {
                    guard let data = try? await item.loadTransferable(type: Data.self),
                          let image = UIImage(data: data) else { return nil }
                    return image
                }
            }

            var results: [UIImage] = []
            for await image in group {
                if let image { results.append(image) }
            }
            return results
        }

        await MainActor.run {
            attachedImages.append(contentsOf: loaded)
            photoPickerItems = []
        }
    }

    private func attachedImagesPreview(images: [UIImage]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(images.count == 1 ? "1 ảnh đã đính kèm" : "\(images.count) ảnh đã đính kèm")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Bạn có thể gửi kèm ảnh cùng câu hỏi.")
                        .font(.system(size: 12))
                        .foregroundColor(Color(.secondaryLabel))
                }
                Spacer()
                Button {
                    clearDraftAttachments()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color(.secondaryLabel))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color(.tertiarySystemBackground)))
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(images.enumerated()), id: \.offset) { index, image in
                        ZStack(alignment: .topTrailing) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 76, height: 76)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .clipped()

                            Button {
                                attachedImages.remove(at: index)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundColor(.white)
                            }
                            .offset(x: 6, y: -6)
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    // MARK: - Visual Helpers

    private var workspaceBackground: some View {
        LinearGradient(
            colors: [Color(.systemBackground), Color.cyan.opacity(0.05), Color(.systemBackground)],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    private var topPills: [TopPill] {
        [
            TopPill(text: "Ống dạ dày", color: .gray),
            TopPill(text: "Khẩn cấp", color: .red)
        ]
    }

    private var filteredConversationSections: [ChatConversationSection] {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return viewModel.conversationSections }
        let query = searchText.lowercased()
        return viewModel.conversationSections.compactMap { section in
            let filteredItems = section.items.filter {
                $0.title.lowercased().contains(query) || $0.preview.lowercased().contains(query)
            }
            return filteredItems.isEmpty ? nil : ChatConversationSection(id: section.id, title: section.title, items: filteredItems)
        }
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.locale = appLanguage.locale
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func statusLabel(for status: LLMBackendStatus) -> String {
        switch status {
        case .mock: return "Mock service"
        case .mockWithDownloadedModel: return "Mô hình đang hoạt động"
        case .loading: return "Đang tải model..."
        case .localModelReady: return "Mô hình đang hoạt động"
        case .unavailable: return "Mô hình không sẵn sàng"
        }
    }

    private func statusColor(for status: LLMBackendStatus) -> Color {
        switch status {
        case .mock, .mockWithDownloadedModel, .localModelReady: return .green
        case .loading: return .orange
        case .unavailable: return .red
        }
    }

    private var quickQuestions: [QuickQuestion] {
        [
            .init(icon: "pills", title: "Thuốc sau mổ", prompt: "Tôi cần uống thuốc gì sau phẫu thuật đại trực tràng và các tác dụng phụ thường gặp là gì?"),
            .init(icon: "fork.knife", title: "Chế độ ăn", prompt: "Thực phẩm nào an toàn để ăn trong 4 tuần đầu sau phẫu thuật đại trực tràng?"),
            .init(icon: "waveform.path.ecg", title: "Kiểm soát đau", prompt: "Tôi bị đau bụng nhẹ 2 tuần sau mổ. Điều này có bình thường không?"),
            .init(icon: "figure.walk", title: "Mức độ hoạt động", prompt: "Khi nào tôi có thể quay lại tập thể dục nhẹ sau phẫu thuật đại trực tràng?")
        ]
    }
}

// MARK: - Helper Views

private struct QuickQuestion: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let prompt: String
}

private struct TopPill: Identifiable {
    let id = UUID()
    let text: String
    let color: Color
}

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
    }
}

#Preview {
    ChatWorkspaceView(llmService: MockLLMService())
}
