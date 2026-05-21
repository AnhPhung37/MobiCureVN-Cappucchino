import Foundation

/// Output GuardRail: validates responses before streaming to user
/// Checks:
/// 1. Emergency detection (stop and redirect)
/// 2. Hallucination/unsafe advice detection
/// 3. Confidence threshold (only answer if confident + has citations)
/// 4. Citation enforcement (medical advice MUST have source)
final class OutputGuardRail {

    // Compiled once at class load time — recreating NSRegularExpression per-call causes malloc errors under load
    private static let hallucinationRegexes: [NSRegularExpression] = GuardRailRules.hallucinationIndicators.compactMap {
        try? NSRegularExpression(pattern: $0, options: [.caseInsensitive])
    }
    private static let unsafeDosageRegexes: [NSRegularExpression] = GuardRailRules.unsafeDosagePatterns.compactMap {
        try? NSRegularExpression(pattern: $0, options: [.caseInsensitive])
    }

    init() {}
    
    /// Check LLM response against output safety rules
    /// Parameters:
    /// - response: raw LLM output
    /// - retrievedContext: context chunks + confidence score from retrieval
    /// - originalQuery: user's query (for emergency detection)
    func validate(
        response: String,
        retrievedContext: RetrievedContext?,
        originalQuery: String
    ) -> OutputGuardRailResult {
        var issues: [String] = []
        
        // Check 1: Emergency Detection (highest priority)
        let emergencyResult = detectEmergency(in: originalQuery)
        if emergencyResult.isEmergency {
            issues.append("Emergency detected: \(emergencyResult.symptomType?.rawValue ?? "unknown")")
            let emergencyResponse = EmergencyResponses.templates[emergencyResult.symptomType!] ?? ""
            return OutputGuardRailResult(
                status: .blocked(reason: "Emergency detected"),
                originalResponse: response,
                filteredResponse: emergencyResponse,
                issues: issues,
                requiresEmergencyResponse: true,
                confidenceScore: 0.0
            )
        }
        
        // Check 2: Citation Enforcement
        let hasCitations = responseMentionsCitations(response) || (retrievedContext?.sources.count ?? 0) > 0
        if !hasCitations && isMedicalAdvice(response) {
            issues.append("Medical advice without citations")
            let enhancedResponse = addCitationReminder(response, context: retrievedContext)
            return OutputGuardRailResult(
                status: .blocked(reason: "Medical advice requires citations"),
                originalResponse: response,
                filteredResponse: enhancedResponse,
                issues: issues,
                confidenceScore: 0.0
            )
        }
        
        // Check 3: Confidence Threshold
        let confidenceScore = retrievedContext?.confidenceScore ?? 0.5
        if confidenceScore < GuardRailRules.minMedicalConfidenceThreshold && isMedicalAdvice(response) {
            issues.append("Low confidence: \(String(format: "%.2f", confidenceScore)) < \(GuardRailRules.minMedicalConfidenceThreshold)")
            let cautionResponse = addLowConfidenceWarning(response)
            return OutputGuardRailResult(
                status: .blocked(reason: "Insufficient retrieval confidence"),
                originalResponse: response,
                filteredResponse: cautionResponse,
                issues: issues,
                confidenceScore: confidenceScore
            )
        }
        
        // Check 4: Hallucination Detection
        if let hallucinationIssue = detectHallucination(response) {
            issues.append(hallucinationIssue)
            let filteredResponse = removeHallucinatedClaims(response)
            return OutputGuardRailResult(
                status: .blocked(reason: "Hallucinated medical advice detected"),
                originalResponse: response,
                filteredResponse: filteredResponse,
                issues: issues,
                confidenceScore: confidenceScore
            )
        }
        
        // Check 5: Unsafe Dosage Detection
        if let unsafeDosageIssue = detectUnsafeDosage(response) {
            issues.append(unsafeDosageIssue)
            let filteredResponse = removeUnsafeDosage(response)
            return OutputGuardRailResult(
                status: .blocked(reason: "Unsafe dosage information detected"),
                originalResponse: response,
                filteredResponse: filteredResponse,
                issues: issues,
                confidenceScore: confidenceScore
            )
        }
        
        // All checks passed - safe to return
        return OutputGuardRailResult(
            status: .allowed,
            originalResponse: response,
            filteredResponse: response,
            issues: issues,
            confidenceScore: confidenceScore
        )
    }
    
    // MARK: - Private Detectors
    
    /// Detect emergency symptoms in user query
    private func detectEmergency(in query: String) -> EmergencyDetectionResult {
        let lower = query.lowercased()
        
        for (symptomPattern, symptomType) in GuardRailRules.emergencySymptomPatterns {
            if lower.contains(symptomPattern.lowercased()) {
                let recommendation = EmergencyResponses.templates[symptomType]
                return EmergencyDetectionResult(
                    isEmergency: true,
                    symptomType: symptomType,
                    recommendation: recommendation
                )
            }
        }
        
        return EmergencyDetectionResult(isEmergency: false)
    }
    
    /// Detect hallucinated medical advice (definitive claims, unrealistic claims)
    private func detectHallucination(_ response: String) -> String? {
        let lower = response.lowercased()
        let range = NSRange(lower.startIndex..<lower.endIndex, in: lower)
        for (regex, indicator) in zip(Self.hallucinationRegexes, GuardRailRules.hallucinationIndicators) {
            if regex.firstMatch(in: lower, options: [], range: range) != nil {
                return "Hallucinated claim detected: \(indicator)"
            }
        }
        return nil
    }

    /// Detect unsafe dosage information
    private func detectUnsafeDosage(_ response: String) -> String? {
        let lower = response.lowercased()
        let range = NSRange(lower.startIndex..<lower.endIndex, in: lower)
        for (regex, pattern) in zip(Self.unsafeDosageRegexes, GuardRailRules.unsafeDosagePatterns) {
            if regex.firstMatch(in: lower, options: [], range: range) != nil {
                return "Unsafe dosage detected: \(pattern)"
            }
        }
        return nil
    }
    
    /// Check if response mentions citations
    private func responseMentionsCitations(_ response: String) -> Bool {
        let citationKeywords = ["source", "according to", "based on", "reference", "study", "research", "doi:", "pubmed"]
        let lower = response.lowercased()
        
        return citationKeywords.contains(where: { lower.contains($0) })
    }
    
    /// Check if response is giving medical advice (not just information)
    private func isMedicalAdvice(_ response: String) -> Bool {
        let adviceKeywords = ["should", "recommend", "take", "avoid", "stop", "start", "try", "use", "apply"]
        let lower = response.lowercased()
        
        return adviceKeywords.contains(where: { lower.contains($0) })
    }
    
    // MARK: - Response Modifiers
    
    /// Add reminder to include citations
    private func addCitationReminder(_ response: String, context: RetrievedContext?) -> String {
        let citationNote = """
        
        ⚠️ **Important**: This medical information should be verified with your healthcare provider and based on authoritative medical sources.
        """
        
        var result = response + citationNote
        
        if let sources = context?.sources, !sources.isEmpty {
            result += "\n\n**Sources:**\n"
            for source in sources {
                result += "- \(source.title) (Page \(source.page))\n"
            }
        }
        
        return result
    }
    
    /// Add warning for low confidence
    private func addLowConfidenceWarning(_ response: String) -> String {
        let warning = """
        
        ⚠️ **Limitation**: I don't have enough reliable medical context to provide a confident answer. Please consult with a healthcare professional for accurate medical advice.
        """
        return warning + response
    }
    
    /// Remove hallucinated claims from response
    private func removeHallucinatedClaims(_ response: String) -> String {
        var filtered = response
        for regex in Self.hallucinationRegexes {
            let range = NSRange(filtered.startIndex..<filtered.endIndex, in: filtered)
            filtered = regex.stringByReplacingMatches(in: filtered, options: [], range: range,
                                                      withTemplate: "[removed: unverified claim]")
        }
        return filtered
    }

    /// Remove unsafe dosage information
    private func removeUnsafeDosage(_ response: String) -> String {
        var filtered = response
        for regex in Self.unsafeDosageRegexes {
            let range = NSRange(filtered.startIndex..<filtered.endIndex, in: filtered)
            filtered = regex.stringByReplacingMatches(in: filtered, options: [], range: range,
                                                      withTemplate: "[dosage information removed - consult healthcare provider]")
        }
        return filtered
    }
}
