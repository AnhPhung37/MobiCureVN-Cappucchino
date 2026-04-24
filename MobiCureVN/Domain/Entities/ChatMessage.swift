//
//  ChatMessage.swift.swift
//  MobiCureVN
//
//  Created by Anh Phung on 4/24/26.
//

import Foundation

enum MessageRole {
    case user
    case assistant
}

struct ChatMessage: Identifiable {
    let id: UUID
    let role: MessageRole
    var content: String
    var citations: [MedicalSource]
    var isStreaming: Bool
    let timestamp: Date

    init(
        id: UUID = UUID(),
        role: MessageRole,
        content: String = "",
        citations: [MedicalSource] = [],
        isStreaming: Bool = false,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.citations = citations
        self.isStreaming = isStreaming
        self.timestamp = timestamp
    }
}
