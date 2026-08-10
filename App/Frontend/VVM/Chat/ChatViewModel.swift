//
//  ChatViewModel.swift
//  MobiCureVN
//
//  Created by Anh Phung on 4/24/26.
//

import Foundation
import Combine
import SwiftUI

enum ChatError: LocalizedError {
    case streamFailed
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .streamFailed:
            return "Không thể kết nối. Vui lòng thử lại.".localized(for: .current)
        case .emptyResponse:
            return "Không nhận được phản hồi. Vui lòng thử lại.".localized(for: .current)
        }
    }
}

@MainActor
final class ChatViewModel: ObservableObject {

    // MARK: - Published State

    @Published var messages: [ChatMessage] = []
    @Published var inputText: String = ""
    @Published var isLoading: Bool = false
    @Published var errorMessage: String? = nil
    @Published var backendStatus: LLMBackendStatus = .mock
    @Published var downloadProgress: Double = 0
    /// Per-model background-download progress (0...1), keyed by model. Non-empty while one or
    /// more models are downloading in parallel; drives the picker's per-row "downloading… %"
    /// state so the user can still pick an already-downloaded model meanwhile.
    @Published private(set) var downloadingModels: [ModelCatalog: Double] = [:]
    /// True when the currently loading model has no valid files on disk yet, i.e. this
    /// `.loading` run is a real first-time download+install rather than a quick reload of
    /// weights already cached from a previous launch. Drives the "first load can take a
    /// while" hint so it isn't shown on every routine relaunch.
    @Published private(set) var isFirstTimeModelSetup: Bool = false
    @Published private(set) var processingState: ChatProcessingState = .idle

    @Published var sections: [ChatSection] = []
    @Published var conversationSections: [ChatConversationSection] = []

    /// Identifies the bubble currently showing unvalidated draft text, so the view can mark it
    /// as still being written. `nil` whenever nothing is streaming.
    @Published private(set) var streamingMessageID: UUID?

    // MARK: - Dependencies

    private var chatService: ChatService
    private let historyRepository: ChatHistoryRepository
    @Published private(set) var currentConversationId: UUID = UUID()

    private var streamingTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    private var messageDates: [Date] = []
    /// Stable identity per message, kept in step with `messages`/`messageDates`. `ChatItem` is
    /// rebuilt from scratch on every `rebuildSections()` — which now happens ~20×/second while
    /// a reply streams — so minting a fresh UUID there would give every row a new identity on
    /// each frame and make SwiftUI tear down and rebuild the whole list instead of diffing it.
    private var messageIDs: [UUID] = []

    // MARK: - Init

    init(
        llmService: LLMServiceProtocol? = nil,
        historyRepository: ChatHistoryRepository? = nil
    ) {
        let orchestrator = MedicalChatOrchestrator(llmService: llmService ?? AppConfig.llmService)
        self.chatService = ChatService(
            orchestrator: orchestrator,
            translationService: AppConfig.translationService
        )
        self.historyRepository = historyRepository ?? AppConfig.chatHistoryRepository

        backendStatus = AppConfig.llmStatus
        downloadProgress = AppConfig.llmDownloadProgress
        downloadingModels = AppConfig.modelDownloadProgress
        isFirstTimeModelSetup = !ModelManager.shared.isModelDownloaded(repoID: AppConfig.selectedModel.repoID)
        bindLLMStatusUpdates()

        Task { await self.bootstrapHistory() }
    }

    private func bindLLMStatusUpdates() {
        NotificationCenter.default.publisher(for: AppConfig.llmStatusDidChange)
            .compactMap { $0.userInfo?[AppConfig.llmStatusUserInfoKey] as? LLMBackendStatus }
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                guard let self else { return }
                if status == .loading, self.backendStatus != .loading {
                    self.isFirstTimeModelSetup = !ModelManager.shared.isModelDownloaded(repoID: AppConfig.selectedModel.repoID)
                }
                self.backendStatus = status
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: AppConfig.llmServiceDidChange)
            .compactMap { $0.userInfo?[AppConfig.llmServiceUserInfoKey] as? LLMServiceProtocol }
            .receive(on: RunLoop.main)
            .sink { [weak self] service in
                guard let self else { return }
                self.chatService.updateOrchestrator(MedicalChatOrchestrator(llmService: service))
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: AppConfig.llmDownloadProgressDidChange)
            .compactMap { $0.userInfo?[AppConfig.llmDownloadProgressUserInfoKey] as? Double }
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.downloadProgress = value
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: AppConfig.modelDownloadsDidChange)
            .compactMap { $0.userInfo?[AppConfig.modelDownloadsUserInfoKey] as? [ModelCatalog: Double] }
            .receive(on: RunLoop.main)
            .sink { [weak self] progress in
                self?.downloadingModels = progress
            }
            .store(in: &cancellables)

        // Forward ChatService processing state so the view only needs to observe this ViewModel.
        chatService.$processingState
            .receive(on: RunLoop.main)
            .assign(to: &$processingState)
    }

    // MARK: - Chat History Grouping

    private func itemsAsChatItems() -> [ChatItem] {
        messages.indices.compactMap { index in
            guard messageDates.indices.contains(index),
                  messageIDs.indices.contains(index) else { return nil }
            let message = messages[index]
            return ChatItem(
                id: messageIDs[index],
                conversationId: currentConversationId,
                role: message.role,
                content: message.content,
                date: messageDates[index],
                sources: message.sources,
                imageData: message.imageData,
                profileUpdateProposals: message.profileUpdateProposals
            )
        }
    }

    private func rebuildSections(now: Date = Date()) {
        self.sections = ChatGrouper.group(self.itemsAsChatItems(), now: now)
    }

    // MARK: - Actions

    func sendMessage(
        prompt: String? = nil,
        displayContent: String? = nil,
        attachedImageData: [Data] = []
    ) {
        let text = (prompt ?? inputText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isLoading else { return }

        let bubbleText = (displayContent ?? text).trimmingCharacters(in: .whitespacesAndNewlines)
        appendUserMessage(bubbleText, imageData: attachedImageData)
        let assistantIndex = appendAssistantPlaceholder()
        rebuildSections()

        // Captures the sources retrieved during generation so citations can be attached
        // without a second retrieval (the orchestrator already retrieved this context).
        let sourcesBox = SourcesBox()
        let profileUpdatesBox = ProfileUpdateProposalsBox()
        streamingTask = Task {
            let outcome = await streamResponse(
                for: text,
                images: attachedImageData,
                assistantIndex: assistantIndex,
                sourcesBox: sourcesBox,
                profileUpdatesBox: profileUpdatesBox
            )
            // The validated answer only arrives at the very end, so a cancel (Stop button /
            // clear / switch) leaves `finalText` empty even when draft text was on screen.
            // Don't run the normal finalize — it would overwrite the bubble with an error and
            // persist it; keep whatever draft the user already saw instead.
            guard !Task.isCancelled else {
                handleCancelledGeneration(partialText: outcome.interruptedText, assistantIndex: assistantIndex)
                return
            }
            await finalizeResponse(
                outcome.finalText,
                sources: sourcesBox.get(),
                profileUpdateProposals: profileUpdatesBox.get(),
                assistantIndex: assistantIndex
            )
        }
    }

    /// Wound-photo flow: a VLM pre-step extracts structured visual findings from the photo(s),
    /// then those findings (not the raw photos) drive the normal RAG → LLM → guardrail pipeline
    /// via `ChatService.processQuery` — the same path `sendMessage` uses, so Vietnamese
    /// translation/refine/emergency-detection still apply. Gated behind a dedicated
    /// "Analyze Wound" action rather than every image attachment, since ordinary chat photos
    /// (e.g. medication labels) shouldn't pay for the extra VLM hop and model swap.
    func analyzeWoundPhotos(_ images: [UIImage], userNote: String = "") {
        guard !images.isEmpty, !isLoading else { return }
        let attachedImageData = images.compactMap { $0.attachmentJPEGData() }
        guard !attachedImageData.isEmpty else { return }

        let bubbleText = userNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Phân tích ảnh vết thương".localized(for: .current)
            : userNote
        appendUserMessage(bubbleText, imageData: attachedImageData)
        let assistantIndex = appendAssistantPlaceholder()
        rebuildSections()

        let sourcesBox = SourcesBox()
        let profileUpdatesBox = ProfileUpdateProposalsBox()
        streamingTask = Task {
            processingState = .generating
            // analyzeWound also persists a structured WoundLogEntry (parsed findings + saved
            // photo) to AppConfig.woundLogRepository as a side effect; here we only need the
            // findings text to drive the chat pipeline below.
            let findings = await WoundAnalysisService.analyzeWound(images: attachedImageData).findings
            guard !Task.isCancelled else {
                handleCancelledGeneration(partialText: "", assistantIndex: assistantIndex)
                return
            }

            // Findings drive RAG retrieval; the user's own note (if any) is appended so their
            // stated concern still shapes retrieval alongside the VLM's visual observations.
            let query = userNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? findings
                : "\(findings)\n\nPatient note: \(userNote)"

            // images: [] — the text LLM works from the VLM's findings text, not the raw photo;
            // WoundAnalysisService has already swapped the resident model back to a text model.
            let outcome = await streamResponse(
                for: query,
                images: [],
                assistantIndex: assistantIndex,
                sourcesBox: sourcesBox,
                profileUpdatesBox: profileUpdatesBox
            )
            guard !Task.isCancelled else {
                handleCancelledGeneration(partialText: outcome.interruptedText, assistantIndex: assistantIndex)
                return
            }
            await finalizeResponse(
                outcome.finalText,
                sources: sourcesBox.get(),
                profileUpdateProposals: profileUpdatesBox.get(),
                assistantIndex: assistantIndex
            )
        }
    }

    private func appendUserMessage(_ text: String, imageData: [Data] = []) {
        let userMessage = ChatMessage(role: "user", content: text, imageData: imageData)
        messages.append(userMessage)
        messageDates.append(Date())
        messageIDs.append(UUID())
        inputText = ""
        errorMessage = nil
        isLoading = true

        let userItem = ChatItem(
            conversationId: currentConversationId,
            role: userMessage.role,
            content: userMessage.content,
            date: Date(),
            imageData: imageData
        )
        Task { try? await historyRepository.append(userItem) }
        Task { await refreshConversationHistory() }
    }

    private func appendAssistantPlaceholder() -> Int {
        messages.append(ChatMessage(role: "assistant", content: ""))
        messageDates.append(Date())
        messageIDs.append(UUID())
        return messages.count - 1
    }

    /// What a streamed turn produced. `draftText` is raw decoder output that no guardrail has
    /// seen — it is only ever kept when the user cancels mid-reply, so the bubble shows what
    /// they were already reading instead of blanking. `finalText` is the validated answer and
    /// the only text that gets persisted.
    private struct StreamOutcome {
        var finalText: String = ""
        var draftText: String = ""

        /// What to leave on screen when the turn is cut short. Normally the last draft, but a
        /// Stop tapped in the moment between the answer landing and the task noticing the
        /// cancellation must not roll the bubble back to an older draft.
        var interruptedText: String { finalText.isEmpty ? draftText : finalText }
    }

    private func streamResponse(
        for text: String,
        images: [Data],
        assistantIndex: Int,
        sourcesBox: SourcesBox,
        profileUpdatesBox: ProfileUpdateProposalsBox
    ) async ->  StreamOutcome {
        var outcome = StreamOutcome()
        // dropLast(2) excludes the assistant placeholder AND the just-appended user message:
        // the current turn travels separately as `text` + `images`, so leaving it in history
        // would send the user's message to the LLM twice.
        let stream = chatService.processQuery(
            text,
            images: images,
            history: Array(messages.dropLast(2)),
            conversationId: currentConversationId,
            onSourcesRetrieved: { sourcesBox.set($0) },
            onProfileUpdateProposed: { profileUpdatesBox.set($0) }
        )
        defer { streamingMessageID = nil }

        for await event in stream {
            guard !Task.isCancelled else { break }

            let bubbleText: String
            let isDraft: Bool
            switch event {
            case .preview(let draft):
                outcome.draftText = draft
                bubbleText = draft
                isDraft = true
            case .final(let answer):
                outcome.finalText = answer
                bubbleText = answer
                isDraft = false
            }

            // The conversation can be cleared/switched mid-stream; never index past the end.
            guard messages.indices.contains(assistantIndex),
                  messageIDs.indices.contains(assistantIndex) else { break }
            // Marked streaming for previews only — once the final answer lands the bubble is a
            // finished reply, not a draft, and `finalizeResponse` attaches its citations.
            streamingMessageID = isDraft ? messageIDs[assistantIndex] : nil
            messages[assistantIndex] = ChatMessage(role: "assistant", content: bubbleText)
            rebuildSections()
        }
        return outcome
    }

    private func finalizeResponse(
        _ fullText: String,
        sources: [MedicalSource],
        profileUpdateProposals: [ProposedProfileUpdate],
        assistantIndex: Int
    ) async {
        guard messages.indices.contains(assistantIndex) else {
            isLoading = false
            return
        }

        if fullText.isEmpty {
            messages[assistantIndex] = ChatMessage(role: "assistant", content: "Xin lỗi, tôi không thể trả lời lúc này. Vui lòng thử lại.".localized(for: .current))
        } else {
            messageDates[assistantIndex] = Date()
            let assistantItem = ChatItem(
                conversationId: currentConversationId,
                role: "assistant",
                content: fullText,
                date: messageDates[assistantIndex],
                sources: sources
            )
            Task { try? await historyRepository.append(assistantItem) }
            messages[assistantIndex] = ChatMessage(
                role: "assistant",
                content: fullText,
                sources: sources,
                profileUpdateProposals: profileUpdateProposals
            )
        }

        rebuildSections()
        await refreshConversationHistory()
        isLoading = false
    }

    /// Tidy up after the user stops generation. Keeps any partial text that was produced;
    /// otherwise removes the empty assistant placeholder so no blank bubble is left behind.
    private func handleCancelledGeneration(partialText: String, assistantIndex: Int) {
        defer { isLoading = false }
        guard messages.indices.contains(assistantIndex) else { return }

        if partialText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Only remove if this is still the empty placeholder we appended (the message
            // list may have been swapped out by a conversation switch in the meantime).
            let placeholder = messages[assistantIndex]
            guard placeholder.role.lowercased() == "assistant", placeholder.content.isEmpty else { return }
            messages.remove(at: assistantIndex)
            if messageDates.indices.contains(assistantIndex) {
                messageDates.remove(at: assistantIndex)
            }
            if messageIDs.indices.contains(assistantIndex) {
                messageIDs.remove(at: assistantIndex)
            }
        } else {
            messages[assistantIndex] = ChatMessage(role: "assistant", content: partialText)
        }
        rebuildSections()
    }

    // MARK: - Profile Update Confirmation

    /// Patient confirmed a proposed profile change: writes it through to the persisted
    /// profile, resolves the pending record, and updates the inline card's local state.
    func acceptProfileUpdate(_ update: ProposedProfileUpdate) async {
        do {
            let current = try await AppConfig.profileRepository.fetchProfile()
            try await AppConfig.profileRepository.save(current.applying(update))
            try await AppConfig.profileUpdateStore.resolve(id: update.id, status: .accepted)
            updateLocalProposalStatus(id: update.id, status: .accepted)
        } catch {
            errorMessage = "Không thể lưu thay đổi hồ sơ. Vui lòng thử lại.".localized(for: .current)
        }
    }

    /// Patient declined a proposed profile change — nothing is written to the profile.
    func dismissProfileUpdate(_ update: ProposedProfileUpdate) async {
        try? await AppConfig.profileUpdateStore.resolve(id: update.id, status: .dismissed)
        updateLocalProposalStatus(id: update.id, status: .dismissed)
    }

    /// Finds the message carrying `id` among its proposals and marks it resolved, so the
    /// inline card reflects the decision without re-fetching the whole conversation.
    private func updateLocalProposalStatus(id: UUID, status: ProposedProfileUpdate.Status) {
        for index in messages.indices {
            guard let proposalIndex = messages[index].profileUpdateProposals.firstIndex(where: { $0.id == id }) else { continue }
            var updatedProposals = messages[index].profileUpdateProposals
            updatedProposals[proposalIndex].status = status
            messages[index] = ChatMessage(
                role: messages[index].role,
                content: messages[index].content,
                sources: messages[index].sources,
                imageData: messages[index].imageData,
                profileUpdateProposals: updatedProposals
            )
            break
        }
        rebuildSections()
    }

    func cancelStreaming() {
        streamingTask?.cancel()
        streamingTask = nil
        streamingMessageID = nil
        isLoading = false
    }

    func clearConversation() {
        cancelStreaming()
        messages = []
        messageDates = []
        messageIDs = []
        sections = []
        errorMessage = nil
        currentConversationId = UUID()
    }

    func loadConversation(_ conversationId: UUID) async {
        currentConversationId = conversationId
        let items = (try? await historyRepository.loadHistory(conversationId: conversationId)) ?? []
        await MainActor.run {
            self.applyLoadedHistory(items)
        }
        await refreshConversationHistory()
    }

    func deleteConversation(_ conversationId: UUID) async {
        do {
            try await historyRepository.deleteConversation(id: conversationId)
            if currentConversationId == conversationId {
                clearConversation()
            }
            await refreshConversationHistory()
        } catch {
            await MainActor.run {
                self.errorMessage = "Không thể xoá cuộc trò chuyện này.".localized(for: .current)
            }
        }
    }

    // MARK: - History Loading

    func bootstrapHistory() async {
        let conversations = (try? await historyRepository.loadConversations()) ?? []
        await MainActor.run {
            self.conversationSections = ChatConversationGrouper.group(conversations)
        }
        if let latestConversation = conversations.first {
            currentConversationId = latestConversation.id
            let items = (try? await historyRepository.loadHistory(conversationId: latestConversation.id)) ?? []
            await MainActor.run {
                self.applyLoadedHistory(items)
            }
        }
    }

    private func refreshConversationHistory() async {
        let conversations = (try? await historyRepository.loadConversations()) ?? []
        await MainActor.run {
            self.conversationSections = ChatConversationGrouper.group(conversations)
        }
    }

    @MainActor
    private func applyLoadedHistory(_ items: [ChatItem]) {
        self.messages = items.map { ChatMessage(role: $0.role, content: $0.content, sources: $0.sources, imageData: $0.imageData) }
        self.messageDates = items.map { $0.date }
        // Reuse the stored ids rather than minting new ones, so a loaded conversation keeps
        // stable row identity too.
        self.messageIDs = items.map { $0.id }
        self.streamingMessageID = nil
        self.rebuildSections()
    }

    // MARK: - Processing State Label (for the UI)

    var processingStateLabel: String? {
        switch processingState {
        case .idle:                return nil
        case .validatingLanguage:  return "Đang kiểm tra ngôn ngữ..."
        case .refiningInput:       return "Đang xử lý câu hỏi..."
        case .translatingInput:    return "Đang dịch câu hỏi..."
        case .generating:          return "Đang soạn câu trả lời..."
        case .translatingOutput:   return "Đang dịch câu trả lời..."
        }
    }
}

/// Thread-safe holder that carries the sources retrieved on the (background) generation
/// task back to this @MainActor view model once streaming completes.
private nonisolated final class SourcesBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [MedicalSource] = []

    func set(_ newValue: [MedicalSource]) {
        lock.lock(); value = newValue; lock.unlock()
    }

    func get() -> [MedicalSource] {
        lock.lock(); defer { lock.unlock() }; return value
    }
}

/// Thread-safe holder that carries the profile-update proposals generated on the (background)
/// generation task back to this @MainActor view model once streaming completes. Mirrors
/// `SourcesBox`.
private nonisolated final class ProfileUpdateProposalsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [ProposedProfileUpdate] = []

    func set(_ newValue: [ProposedProfileUpdate]) {
        lock.lock(); value = newValue; lock.unlock()
    }

    func get() -> [ProposedProfileUpdate] {
        lock.lock(); defer { lock.unlock() }; return value
    }
}
