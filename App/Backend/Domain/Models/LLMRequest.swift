//
//  LLMRequest.swift
//  MobiCureVN
//
//  Created by Anh Phung on 4/24/26.
//

import Foundation

nonisolated struct LLMRequest {
    let systemPrompt: String
    let userMessage: String
    let conversationHistory: [ChatMessage]

    init(
        systemPrompt: String = "",
        userMessage: String,
        conversationHistory: [ChatMessage] = []
    ) {
        self.systemPrompt = systemPrompt
        self.userMessage = userMessage
        self.conversationHistory = conversationHistory
    }
}
