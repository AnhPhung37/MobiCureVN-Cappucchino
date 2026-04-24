//
//  LLMRequest.swift
//  MobiCureVN
//
//  Created by Anh Phung on 4/24/26.
//

import Foundation

struct LLMParameters {
    var temperature: Float = 0.7
    var maxTokens: Int = 512
    var topP: Float = 0.9
    var repeatPenalty: Float = 1.1
}

struct LLMRequest {
    let systemPrompt: String
    let userMessage: String
    let conversationHistory: [ChatMessage]
    let parameters: LLMParameters

    init(
        systemPrompt: String = "",
        userMessage: String,
        conversationHistory: [ChatMessage] = [],
        parameters: LLMParameters = LLMParameters()
    ) {
        self.systemPrompt = systemPrompt
        self.userMessage = userMessage
        self.conversationHistory = conversationHistory
        self.parameters = parameters
    }
}
