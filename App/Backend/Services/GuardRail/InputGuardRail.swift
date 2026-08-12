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
nonisolated final class InputGuardRail {

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

        // Rule Group 4: PII Detection + Masking — a single pass over the regexes produces both
        // the masked text and the per-label counts. This used to run every PII regex twice
        // (once to mask, once to report), over the same query, on every turn.
        let pii = Self.maskAndDetectPII(in: sanitizedQuery)
        sanitizedQuery = pii.masked
        if !pii.issues.isEmpty {
            violations.append(contentsOf: pii.issues)
            // DEBUG-only: the labels name which KIND of PII was found, never the value, but a
            // release build has no reason to log anything about the patient's message.
            #if DEBUG
            print("InputGuardRail: PII detected and masked: \(pii.issues)")
            #endif
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
        Self.firstMatch(of: GuardRailRules.dangerousPatterns, in: query)
            .map { "Dangerous request detected: \($0)" }
    }

    /// Rule Group 3: Detect prompt injection / jailbreak attempts
    private func checkPromptInjection(_ query: String) -> String? {
        Self.firstMatch(of: GuardRailRules.injectionPatterns, in: query)
            .map { "Potential injection: \($0)" }
    }

    /// First pattern from `patterns` that occurs in `query`, compared case-insensitively.
    ///
    /// Both callers used to allocate a lowercased copy of the query AND a lowercased copy of
    /// every pattern, on every keystroke-length message, on every turn.
    /// `range(of:options:.caseInsensitive)` folds case during the comparison instead, so no
    /// copies are made at all.
    ///
    /// Deliberately NOT cached in a `static let` of pre-lowercased patterns, the way
    /// `piiRegexes` is: these two lists are the safety-critical ones and are overridable at
    /// launch from `GuardRailRules.json`, so a cache that captured the built-in defaults before
    /// the override loaded would silently enforce the wrong policy. That is a safety bug, not a
    /// performance win.
    private static func firstMatch(of patterns: [String], in query: String) -> String? {
        patterns.first { pattern in
            !pattern.isEmpty && query.range(of: pattern, options: .caseInsensitive) != nil
        }
    }
    
    /// Rule Group 4: mask PII and report what was found, in one scan per pattern.
    ///
    /// This replaces a `maskPII` + `detectPII` pair that each ran the full regex list over the
    /// query separately — twice the scanning for one answer. Each pattern is now matched once
    /// and the same match set is used both to count and to substitute.
    ///
    /// Substitution walks the matches in reverse so earlier ranges stay valid as later ones are
    /// replaced. Counting against the progressively-masked text (rather than the pristine
    /// query) also means one piece of PII nested inside another is reported once rather than
    /// twice — the previous behaviour was double-reporting, not extra detection.
    private static func maskAndDetectPII(in query: String) -> (masked: String, issues: [String]) {
        var masked = query
        var issues: [String] = []

        for (regex, label) in piiRegexes {
            let range = NSRange(masked.startIndex..<masked.endIndex, in: masked)
            let matches = regex.matches(in: masked, options: [], range: range)
            guard !matches.isEmpty else { continue }

            issues.append("Found \(label): \(matches.count) instance(s)")
            for match in matches.reversed() {
                guard let matchRange = Range(match.range, in: masked) else { continue }
                masked.replaceSubrange(matchRange, with: "[MASKED]")
            }
        }

        return (masked, issues)
    }
}
