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

    // MARK: - Dependencies

    private let llmService: LLMServiceProtocol
    private var streamingTask: Task<Void, Never>?

    // MARK: - Mock Citations

    static let mockCitations: [MedicalSource] = [
        MedicalSource(
            id: "1",
            title: "Hướng dẫn chăm sóc sau phẫu thuật đại trực tràng",
            excerpt: "Các dấu hiệu nhiễm trùng vết mổ cần được theo dõi hàng ngày...",
            page: 12,
            documentName: "Post-Surgery Care Protocol 2024"
        ),
        MedicalSource(
            id: "2",
            title: "Quản lý đau sau phẫu thuật",
            excerpt: "Đau ở mức độ vừa phải là bình thường trong 3-5 ngày đầu...",
            page: 8,
            documentName: "Pain Management Guidelines"
        )
    ]

    // MARK: - Init

    init(llmService: LLMServiceProtocol) {
        self.llmService = llmService
    }

    // MARK: - Actions

    func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isLoading else { return }

        // Add user message
        let userMessage = ChatMessage(role: .user, content: text)
        messages.append(userMessage)
        inputText = ""
        errorMessage = nil
        isLoading = true

        // Add placeholder assistant message for streaming
        let assistantMessage = ChatMessage(
            role: .assistant,
            content: "",
            citations: [],
            isStreaming: true
        )
        messages.append(assistantMessage)
        let assistantIndex = messages.count - 1

        // Stream response
        streamingTask = Task {
            let request = LLMRequest(userMessage: text, conversationHistory: messages)
            var fullText = ""

            for await token in llmService.stream(request: request) {
                guard !Task.isCancelled else { break }
                fullText += token
                messages[assistantIndex].content = fullText
            }

            // Finalize message
            if fullText.isEmpty {
                messages[assistantIndex].content = "Xin lỗi, tôi không thể trả lời lúc này. Vui lòng thử lại."
            }

            // Attach mock citations to every assistant response
            messages[assistantIndex].citations = Self.mockCitations
            messages[assistantIndex].isStreaming = false
            isLoading = false
        }
    }

    func cancelStreaming() {
        streamingTask?.cancel()
        streamingTask = nil
        if let last = messages.last, last.isStreaming {
            messages[messages.count - 1].isStreaming = false
        }
        isLoading = false
    }

    func clearConversation() {
        cancelStreaming()
        messages = []
        errorMessage = nil
    }
}
