//
//  StructuredLLMService.swift
//  MobiCureVN
//

import Foundation
import FoundationModels

/// A backend that can constrain generation to a schema, so the reply decodes deterministically
/// instead of being scraped out of free text.
///
/// Deliberately a *separate* protocol rather than a requirement added to `LLMServiceProtocol`:
/// `Generable` is iOS 26+, and the MLX backends — which serve every device below that, every
/// image-bearing request, and the whole Vietnamese chat path — have no equivalent. Call sites
/// conditionally cast (`llmService as? any StructuredLLMService`) and keep their existing
/// text-and-parse path as the fallback, so behaviour is unchanged wherever the system model
/// can't serve.
///
/// Only worth adopting for *extraction* work, where the output is a data structure and a parse
/// failure silently drops information. Prose generation gains nothing from a schema.
@available(iOS 26.0, *)
protocol StructuredLLMService: LLMServiceProtocol {

    /// Generates a value of `Content`, guaranteed to match its generated schema.
    ///
    /// - Parameter prompt: the user turn — the data being extracted from.
    /// - Parameter instructions: developer-role content (the extraction rules). Kept out of the
    ///   user turn so the rules can't be overridden by text quoted inside `prompt`.
    /// - Throws: `LanguageModelSession.GenerationError` on guardrail refusal, context overflow,
    ///   or asset failure. Callers are expected to treat a throw as "extracted nothing" and fall
    ///   back, never to surface it — same fail-closed contract the text path already has.
    func respond<Content: Generable>(
        to prompt: String,
        instructions: String,
        generating: Content.Type
    ) async throws -> Content
}
