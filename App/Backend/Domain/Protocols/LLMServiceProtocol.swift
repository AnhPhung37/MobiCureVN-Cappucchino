//
//  LLMServiceProtocol.swift
//  MobiCureVN
//
//  Created by Anh Phung on 4/24/26.
//

import Foundation

/// How a generation ended, when the backend can tell.
nonisolated enum LLMCompletion: Sendable, Equatable {
    /// Stopped on its own, at an end-of-sequence token.
    case finished
    /// Cut off by the request's token ceiling (`GenerationOptions.maxTokens`) before it finished.
    case truncated
    /// The backend cannot report it, or the generation failed or was cancelled.
    case unknown
}

/// One event of a generation: text chunks in order, then exactly one completion.
nonisolated enum LLMStreamEvent: Sendable, Equatable {
    case text(String)
    case completed(LLMCompletion)
}

protocol LLMServiceProtocol {
    nonisolated func stream(request: LLMRequest) -> AsyncStream<String>

    /// The same generation as `stream(request:)`, ending with how it stopped. A backend that
    /// cannot tell inherits the default below, which reports `.unknown`.
    nonisolated func streamEvents(request: LLMRequest) -> AsyncStream<LLMStreamEvent>
}

extension LLMServiceProtocol {
    nonisolated func streamEvents(request: LLMRequest) -> AsyncStream<LLMStreamEvent> {
        let text = stream(request: request)
        return AsyncStream { continuation in
            let task = Task {
                for await chunk in text {
                    continuation.yield(.text(chunk))
                }
                continuation.yield(.completed(.unknown))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
