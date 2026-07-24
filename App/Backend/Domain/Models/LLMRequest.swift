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
    /// Images attached to the current user turn (encoded JPEG/PNG), following the
    /// multimodal chat convention: a user turn is text + images travelling together.
    /// Ignored by text-only backends.
    let images: [Data]

    init(
        systemPrompt: String = "",
        userMessage: String,
        conversationHistory: [ChatMessage] = [],
        images: [Data] = []
    ) {
        self.systemPrompt = systemPrompt
        self.userMessage = userMessage
        self.conversationHistory = conversationHistory
        self.images = images
    }
}
