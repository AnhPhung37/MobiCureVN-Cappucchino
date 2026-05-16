//
//  ChatViewModel.swift
//  MobiCureVN
//
//  Created by Anh Phung on 4/24/26.
//

import Foundation
import Combine

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

    // MARK: - Dependencies

    private var orchestrator: MedicalChatOrchestrator

    private var streamingTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    // MARK: - Init

    init(llmService: LLMServiceProtocol) {
        self.orchestrator = MedicalChatOrchestrator(llmService: llmService)

        backendStatus = AppConfig.llmStatus
        downloadProgress = AppConfig.llmDownloadProgress
        bindLLMStatusUpdates()
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
                self?.orchestrator = MedicalChatOrchestrator(llmService: service)

            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: AppConfig.llmDownloadProgressDidChange)
            .compactMap { $0.userInfo?[AppConfig.llmDownloadProgressUserInfoKey] as? Double }
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.downloadProgress = value
            }
            .store(in: &cancellables)
    }

    // MARK: - Actions

    func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isLoading else { return }

        // Add user message
        let userMessage = ChatMessage(role: "user", content: text)
        messages.append(userMessage)
        inputText = ""
        errorMessage = nil
        isLoading = true

        // Add placeholder assistant message for streaming
        let assistantMessage = ChatMessage(role: "assistant", content: "")
        messages.append(assistantMessage)
        let assistantIndex = messages.count - 1

        // Stream response using orchestrator (with guardrails + RAG)
        streamingTask = Task {
            var fullText = ""

            for await token in orchestrator.processQuery(text, conversationHistory: Array(messages.dropLast())) {
                guard !Task.isCancelled else { break }
                fullText += token
                messages[assistantIndex] = ChatMessage(role: "assistant", content: fullText)
            }

            // Finalize message
            if fullText.isEmpty {
                messages[assistantIndex] = ChatMessage(role: "assistant", content: "Xin lỗi, tôi không thể trả lời lúc này. Vui lòng thử lại.")
            }

            isLoading = false
        }
    }

    func cancelStreaming() {
        streamingTask?.cancel()
        streamingTask = nil
        // No streaming flag in current model; nothing to toggle here.
        isLoading = false
    }

    func clearConversation() {
        cancelStreaming()
        messages = []
        errorMessage = nil
    }
}
