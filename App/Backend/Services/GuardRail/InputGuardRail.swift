import Foundation
import NaturalLanguage

/// Input GuardRail: validates queries before they reach LLM
/// Rule Group 1: Domain filter (medical-only)
/// Rule Group 2: Dangerous requests (self-harm, violence, illegal)
/// Rule Group 3: Prompt injection/jailbreak
/// Rule Group 4: PII detection + masking
final class InputGuardRail {

    // Loaded once — sentence embedding initialisation is expensive
    private static let sentenceEmbedding = NLEmbedding.sentenceEmbedding(for: .english)
    // Cosine distance below this → query is semantically close to a medical anchor
    private static let similarityThreshold: NLDistance = 0.45

    init() {}

    /// Check input query against all guardrails.
    /// - Parameters:
    ///   - query: Original user query (any language). Used for dangerous/injection/PII checks.
    ///   - englishQuery: English translation of the query. When provided, used for semantic
    ///     relevance so Vietnamese input is correctly compared against English anchor phrases.
    func validate(query: String, englishQuery: String? = nil) -> InputGuardRailResult {
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

        // Rule Group 4: PII Detection + Masking (before medical check)
        sanitizedQuery = maskPII(sanitizedQuery)
        let piiIssues = detectPII(query)
        if !piiIssues.isEmpty {
            violations.append(contentsOf: piiIssues)
            print("InputGuardRail: PII detected and masked: \(piiIssues)")
        }

        // Rule Group 1: Domain filter — semantic relevance using NLEmbedding.
        // Use the English translation when available so Vietnamese queries are compared
        // against English anchor phrases in the same embedding space.
        let queryForRelevance = englishQuery ?? query
        if !checkMedicalRelevance(queryForRelevance) {
            violations.append("Query not medical-related")
            return InputGuardRailResult(
                status: .blocked(reason: "This question is not medical-related. Please ask medical questions."),
                originalQuery: query,
                sanitizedQuery: sanitizedQuery,
                violations: violations
            )
        }

        return InputGuardRailResult(
            status: .allowed,
            originalQuery: query,
            sanitizedQuery: sanitizedQuery,
            violations: violations
        )
    }
    
    // MARK: - Private Checkers
    
    /// Rule Group 1: Semantic medical relevance check.
    /// Primary: NLEmbedding cosine distance against medical anchor phrases.
    /// Fallback: keyword and intent-pattern matching for when the embedding model is unavailable.
    private func checkMedicalRelevance(_ query: String) -> Bool {
        let lower = query.lowercased()

        if let embedding = Self.sentenceEmbedding {
            let isNearAnchor = GuardRailRules.medicalAnchors.contains { anchor in
                embedding.distance(between: lower, and: anchor) < Self.similarityThreshold
            }
            if isNearAnchor { return true }
        }

        // Fallback: keyword + intent patterns when embedding model is unavailable
        if GuardRailRules.medicalKeywords.contains(where: { lower.contains($0) }) { return true }
        if GuardRailRules.patientIntentPatterns.contains(where: { lower.contains($0) }) { return true }

        return false
    }
    
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
        
        for (pattern, label) in GuardRailRules.piiPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                let range = NSRange(query.startIndex..<query.endIndex, in: query)
                let matches = regex.matches(in: query, options: [], range: range)
                if !matches.isEmpty {
                    piiFound.append("Found \(label): \(matches.count) instance(s)")
                }
            }
        }
        
        return piiFound
    }
    
    /// Rule Group 4: Mask PII in query
    private func maskPII(_ query: String) -> String {
        var masked = query
        
        for (pattern, _) in GuardRailRules.piiPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                let range = NSRange(masked.startIndex..<masked.endIndex, in: masked)
                masked = regex.stringByReplacingMatches(in: masked, options: [], range: range, withTemplate: "[MASKED]")
            }
        }
        
        return masked
    }
}
