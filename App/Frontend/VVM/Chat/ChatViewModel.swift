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
            return "Không thể kết nối. Vui lòng thử lại."
        case .emptyResponse:
            return "Không nhận được phản hồi. Vui lòng thử lại."
        }
    }
}

@MainActor
class ChatViewModel: ObservableObject {

    // MARK: - Published State

    @Published var messages: [ChatMessage] = []
    @Published var inputText: String = ""
    @Published var isLoading: Bool = false
    @Published var errorMessage: String? = nil
    @Published var backendStatus: LLMBackendStatus = .mock
    @Published var downloadProgress: Double = 0
    @Published private(set) var processingState: ChatProcessingState = .idle

    @Published var sections: [ChatSection] = []
    @Published var conversationSections: [ChatConversationSection] = []

    // MARK: - Dependencies

    private var chatService: ChatService
    private let historyRepository: ChatHistoryRepository
    private let citationRetriever = SQLiteRetriever()
    private let queryRefiner = QueryRefiner()
    @Published private(set) var currentConversationId: UUID = UUID()

    private var streamingTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    private var messageDates: [Date] = []

    // MARK: - Init

    init(
        llmService: LLMServiceProtocol? = nil,
        historyRepository: ChatHistoryRepository = AppConfig.chatHistoryRepository
    ) {
        let orchestrator = MedicalChatOrchestrator(llmService: llmService ?? AppConfig.llmService)
        self.chatService = ChatService(
            orchestrator: orchestrator,
            translationService: AppConfig.translationService
        )
        self.historyRepository = historyRepository

        backendStatus = AppConfig.llmStatus
        downloadProgress = AppConfig.llmDownloadProgress
        bindLLMStatusUpdates()

        Task { await self.bootstrapHistory() }
    }

    private func bindLLMStatusUpdates() {
        NotificationCenter.default.publisher(for: AppConfig.llmStatusDidChange)
            .compactMap { $0.userInfo?[AppConfig.llmStatusUserInfoKey] as? LLMBackendStatus }
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                self?.backendStatus = status
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

        // Forward ChatService processing state so the view only needs to observe this ViewModel.
        chatService.$processingState
            .receive(on: RunLoop.main)
            .assign(to: &$processingState)
    }

    // MARK: - Chat History Grouping

    private func itemsAsChatItems() -> [ChatItem] {
        zip(messages, messageDates).map {
            ChatItem(
                conversationId: currentConversationId,
                role: $0.0.role,
                content: $0.0.content,
                date: $0.1,
                sources: $0.0.sources
            )
        }
    }

    private func rebuildSections(now: Date = Date()) {
        self.sections = ChatGrouper.group(self.itemsAsChatItems(), now: now)
    }

    // MARK: - Actions

    func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isLoading else { return }

        appendUserMessage(text)
        let assistantIndex = appendAssistantPlaceholder()
        rebuildSections()

        streamingTask = Task {
            let fullText = await streamResponse(for: text, assistantIndex: assistantIndex)
            await finalizeResponse(fullText, originalQuery: text, assistantIndex: assistantIndex)
        }
    }

    private func appendUserMessage(_ text: String) {
        let userMessage = ChatMessage(role: "user", content: text)
        messages.append(userMessage)
        messageDates.append(Date())
        inputText = ""
        errorMessage = nil
        isLoading = true

        let userItem = ChatItem(conversationId: currentConversationId, role: userMessage.role, content: userMessage.content, date: Date())
        Task { try? await historyRepository.append(userItem) }
        Task { await refreshConversationHistory() }
    }

    private func appendAssistantPlaceholder() -> Int {
        messages.append(ChatMessage(role: "assistant", content: ""))
        messageDates.append(Date())
        return messages.count - 1
    }

    private func streamResponse(for text: String, assistantIndex: Int) async -> String {
        var fullText = ""
        for await token in chatService.processQuery(text, history: Array(messages.dropLast())) {
            guard !Task.isCancelled else { break }
            fullText += token
            messages[assistantIndex] = ChatMessage(role: "assistant", content: fullText)
            rebuildSections()
        }
        return fullText
    }

    private func finalizeResponse(_ fullText: String, originalQuery: String, assistantIndex: Int) async {
        if fullText.isEmpty {
            messages[assistantIndex] = ChatMessage(role: "assistant", content: "Xin lỗi, tôi không thể trả lời lúc này. Vui lòng thử lại.")
        } else {
            messageDates[assistantIndex] = Date()
            let refinedForCitation = queryRefiner.refineQuery(originalQuery)
            let retrieved = citationRetriever.retrieve(
                query: refinedForCitation.baseQuery,
                enrichedTerms: refinedForCitation.enrichedTerms,
                topK: 5
            )
            print("CitationRetriever: query='\(refinedForCitation.baseQuery)' sources=\(retrieved.sources.count)")
            let assistantItem = ChatItem(
                conversationId: currentConversationId,
                role: "assistant",
                content: fullText,
                date: messageDates[assistantIndex]
            )
            Task { try? await historyRepository.append(assistantItem) }
            messages[assistantIndex] = ChatMessage(role: "assistant", content: fullText, sources: retrieved.sources)
        }

        rebuildSections()
        await refreshConversationHistory()
        isLoading = false
    }

    func cancelStreaming() {
        streamingTask?.cancel()
        streamingTask = nil
        isLoading = false
    }

    func clearConversation() {
        cancelStreaming()
        messages = []
        messageDates = []
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
                self.errorMessage = "Không thể xoá cuộc trò chuyện này."
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
        self.messages = items.map { ChatMessage(role: $0.role, content: $0.content) }
        self.messageDates = items.map { $0.date }
        self.rebuildSections()
    }

    // MARK: - Processing State Label (for the UI)

    var processingStateLabel: String? {
        switch processingState {
        case .idle:                return nil
        case .validatingLanguage:  return "Đang kiểm tra ngôn ngữ..."
        case .translatingInput:    return "Đang dịch câu hỏi..."
        case .generating:          return nil   // handled by the existing streaming bubble
        case .translatingOutput:   return "Đang dịch câu trả lời..."
        }
    }
}
