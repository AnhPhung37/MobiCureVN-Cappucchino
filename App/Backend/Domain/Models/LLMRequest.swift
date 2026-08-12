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
    /// Token ceiling and sampling for THIS request. Defaults to `.answer`, so a caller that says
    /// nothing gets what a user-facing medical answer needs; the short auxiliary calls (language
    /// classification, fact extraction, input rewriting) pass a cheaper, deterministic preset
    /// instead of silently inheriting a 1024-token answering budget. See `GenerationOptions`.
    let options: GenerationOptions

    init(
        systemPrompt: String = "",
        userMessage: String,
        conversationHistory: [ChatMessage] = [],
        images: [Data] = [],
        options: GenerationOptions = .answer
    ) {
        self.systemPrompt = systemPrompt
        self.userMessage = userMessage
        self.conversationHistory = conversationHistory
        self.images = images
        self.options = options
    }
}
