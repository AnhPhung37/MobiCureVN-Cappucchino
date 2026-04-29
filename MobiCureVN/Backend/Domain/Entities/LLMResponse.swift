//
//  LLMResponse.swift
//  MobiCureVN
//
//  Created by Anh Phung on 4/24/26.
//

import Foundation

struct LLMResponse {
    let text: String
    let citations: [MedicalSource]
    let tokensUsed: Int

    init(text: String, citations: [MedicalSource] = [], tokensUsed: Int = 0) {
        self.text = text
        self.citations = citations
        self.tokensUsed = tokensUsed
    }
}
