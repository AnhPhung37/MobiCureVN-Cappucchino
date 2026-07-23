import Foundation

/// Input GuardRail: validates queries before they reach LLM.
///
/// Deliberately does NOT gate on topic/medical-relevance. Real patient conversations are
/// full of benign non-clinical turns — "I'm John, I'm 26", "thanks, that helps", "is that
/// normal after a week?" — and hard-blocking those made the assistant feel mechanical and
/// broke the session-memory feature (the fact extractor never saw self-introductions the
/// gate rejected). Steering genuinely off-topic questions back to health is now the LLM's
/// job via the system prompt (see MedicalChatOrchestrator), which handles it as a warm
/// redirect rather than an error. This layer keeps only the checks that must be enforced
/// deterministically before the model runs:
/// Rule Group 2: Dangerous requests (self-harm, violence, illegal) → hard block
/// Rule Group 3: Prompt injection/jailbreak → hard block
/// Rule Group 4: PII detection + masking
final class InputGuardRail {

    // Precompiled once — recreating NSRegularExpression per query is wasteful (and can
    // fail under load). Mirrors the precompilation already done in OutputGuardRail.
    private static let piiRegexes: [(regex: NSRegularExpression, label: String)] =
        GuardRailRules.piiPatterns.compactMap { pattern, label in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
            return (regex, label)
        }

    init() {}

    /// Check input query against all guardrails.
    /// - Parameters:
    ///   - query: Original user query (any language). Used for dangerous/injection/PII checks.
    ///   - englishQuery: Accepted for source-compatibility with callers; no longer used for
    ///     gating now that topic-relevance is handled downstream by the LLM (see the type doc).
    func validate(query: String, englishQuery: String? = nil) -> InputGuardRailResult {
        _ = englishQuery
        var violations: [String] = []
        var sanitizedQuery = query

        // Rule Group 2: Hard-block dangerous requests FIRST (highest priority)
        if let blocked = checkDangerousRequests(query) {
            violations.append(blocked)
            return InputGuardRailResult(
                status: .blocked(reason: "Request violates safety policy"),
                originalQuery: query,
                violations: violations
            )
        }

        // Rule Group 3: Prompt injection/jailbreak detection
        if let injectionReason = checkPromptInjection(query) {
            violations.append(injectionReason)
            return InputGuardRailResult(
                status: .blocked(reason: "Potential prompt injection detected"),
                originalQuery: query,
                violations: violations
            )
        }

        // Rule Group 4: PII Detection + Masking
        sanitizedQuery = maskPII(sanitizedQuery)
        let piiIssues = detectPII(query)
        if !piiIssues.isEmpty {
            violations.append(contentsOf: piiIssues)
            print("InputGuardRail: PII detected and masked: \(piiIssues)")
        }

        // NOTE: No topic/medical-relevance gate here by design. Benign conversational turns
        // (self-introductions, greetings, follow-ups, lifestyle questions) must pass through
        // so the assistant feels natural and session-memory fact extraction can see them.
        // Off-topic queries are redirected conversationally by the LLM, not blocked here.
        return InputGuardRailResult(
            status: .allowed,
            originalQuery: query,
            sanitizedQuery: sanitizedQuery,
            violations: violations
        )
    }
    
    // MARK: - Private Checkers

    /// Rule Group 2: Check for dangerous/harmful requests
    private func checkDangerousRequests(_ query: String) -> String? {
        let lower = query.lowercased()
        
        for pattern in GuardRailRules.dangerousPatterns {
            if lower.contains(pattern.lowercased()) {
                return "Dangerous request detected: \(pattern)"
            }
        }
        
        return nil
    }
    
    /// Rule Group 3: Detect prompt injection / jailbreak attempts
    private func checkPromptInjection(_ query: String) -> String? {
        let lower = query.lowercased()
        
        for pattern in GuardRailRules.injectionPatterns {
            if lower.contains(pattern.lowercased()) {
                return "Potential injection: \(pattern)"
            }
        }
        
        return nil
    }
    
    /// Rule Group 4: Detect PII in query
    private func detectPII(_ query: String) -> [String] {
        var piiFound: [String] = []
        
        let range = NSRange(query.startIndex..<query.endIndex, in: query)
        for (regex, label) in Self.piiRegexes {
            let matches = regex.matches(in: query, options: [], range: range)
            if !matches.isEmpty {
                piiFound.append("Found \(label): \(matches.count) instance(s)")
            }
        }
        
        return piiFound
    }
    
    /// Rule Group 4: Mask PII in query
    private func maskPII(_ query: String) -> String {
        var masked = query
        
        for (regex, _) in Self.piiRegexes {
            let range = NSRange(masked.startIndex..<masked.endIndex, in: masked)
            masked = regex.stringByReplacingMatches(in: masked, options: [], range: range, withTemplate: "[MASKED]")
        }
        
        return masked
    }
}
