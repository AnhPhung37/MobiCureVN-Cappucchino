import Foundation

/// Input GuardRail: validates queries before they reach LLM
/// Rule Group 1: Domain filter (medical-only)
/// Rule Group 2: Dangerous requests (self-harm, violence, illegal)
/// Rule Group 3: Prompt injection/jailbreak
/// Rule Group 4: PII detection + masking
final class InputGuardRail {
    
    init() {}
    
    /// Check input query against all guardrails
    /// Returns: GuardRailStatus and sanitized query (with PII masked)
    func validate(query: String) -> InputGuardRailResult {
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
            // Log warning but don't block - just mask
            print("InputGuardRail: PII detected and masked: \(piiIssues)")
        }
        
        // Rule Group 1: Domain filter (medical relevance)
        if !checkMedicalRelevance(query) {
            violations.append("Query not medical-related")
            return InputGuardRailResult(
                status: .blocked(reason: "This question is not medical-related. Please ask medical questions."),
                originalQuery: query,
                sanitizedQuery: sanitizedQuery,
                violations: violations
            )
        }
        
        // All checks passed
        return InputGuardRailResult(
            status: .allowed,
            originalQuery: query,
            sanitizedQuery: sanitizedQuery,
            violations: violations
        )
    }
    
    // MARK: - Private Checkers
    
    /// Rule Group 1: Check if query is medical-related
    private func checkMedicalRelevance(_ query: String) -> Bool {
        let lower = query.lowercased()
        
        // Quick check: does it contain any medical keyword?
        for keyword in GuardRailRules.medicalKeywords {
            if lower.contains(keyword) {
                return true
            }
        }
        
        // If very short and no keywords, reject
        if query.trimmingCharacters(in: .whitespaces).count < 5 {
            return false
        }
        
        // Future: add semantic medical classifier here
        // For MVP: keyword-based is sufficient
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
