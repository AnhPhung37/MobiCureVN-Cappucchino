import Foundation

/// Output GuardRail: validates the buffered LLM response before it is delivered to the user.
/// Checks (in order):
/// 1. Citation enforcement (medical advice MUST have a source)
/// 2. Confidence threshold (only answer if retrieval was confident)
/// 3. Hallucination / unsafe-advice detection
/// 4. Unsafe dosage detection
/// Emergency detection runs upstream in MedicalChatOrchestrator, not here.
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
    /// - responseLanguage: language the response was generated in. Only affects the text this
    ///   guardrail *appends* (citation reminders, warnings, redaction markers) — the detection
    ///   rules themselves are bilingual. Without it a Vietnamese answer would come back with
    ///   an English warning stapled to the end.
    func validate(
        response: String,
        retrievedContext: RetrievedContext?,
        responseLanguage: DetectedLanguage = .english
    ) -> OutputGuardRailResult {
        var issues: [String] = []
        let vi = responseLanguage.requiresTranslation

        // Emergency is already handled upstream in MedicalChatOrchestrator before the
        // LLM is ever called, so we skip it here to avoid a redundant check.

        // Check 1: Citation Enforcement.
        // Medical advice must be grounded: either the response references its sources in-text,
        // OR retrieved sources exist (the UI renders them as citation cards beneath the answer).
        // Advice with neither is blocked and enhanced with an appended source list. The teeth
        // of this check come from a broad `isMedicalAdvice` (below), so it fires on real advice
        // rather than being skipped because the phrasing wasn't recognised.
        let hasCitations = responseMentionsCitations(response) || (retrievedContext?.sources.count ?? 0) > 0
        if !hasCitations && isMedicalAdvice(response) {
            issues.append("Medical advice without citations")
            let enhancedResponse = addCitationReminder(response, context: retrievedContext, vietnamese: vi)
            return OutputGuardRailResult(
                status: .blocked(reason: "Medical advice requires citations"),
                originalResponse: response,
                filteredResponse: enhancedResponse,
                issues: issues,
                confidenceScore: 0.0
            )
        }
        
        // Check 2: Confidence Threshold
        let confidenceScore = retrievedContext?.confidenceScore ?? 0.5
        if confidenceScore < GuardRailRules.minMedicalConfidenceThreshold && isMedicalAdvice(response) {
            issues.append("Low confidence: \(String(format: "%.2f", confidenceScore)) < \(GuardRailRules.minMedicalConfidenceThreshold)")
            let cautionResponse = addLowConfidenceWarning(response, vietnamese: vi)
            return OutputGuardRailResult(
                status: .blocked(reason: "Insufficient retrieval confidence"),
                originalResponse: response,
                filteredResponse: cautionResponse,
                issues: issues,
                confidenceScore: confidenceScore
            )
        }
        
        // Check 3: Hallucination Detection
        if let hallucinationIssue = detectHallucination(response) {
            issues.append(hallucinationIssue)
            let filteredResponse = removeHallucinatedClaims(response, vietnamese: vi)
            return OutputGuardRailResult(
                status: .blocked(reason: "Hallucinated medical advice detected"),
                originalResponse: response,
                filteredResponse: filteredResponse,
                issues: issues,
                confidenceScore: confidenceScore
            )
        }
        
        // Check 4: Unsafe Dosage Detection
        if let unsafeDosageIssue = detectUnsafeDosage(response) {
            issues.append(unsafeDosageIssue)
            let filteredResponse = removeUnsafeDosage(response, vietnamese: vi)
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
    
    /// Check if response mentions citations. Keyword list lives in GuardRailRules so it stays
    /// bilingual alongside the other output rules — responses reach this check in Vietnamese
    /// as well as English now that the model answers in the user's language directly.
    private func responseMentionsCitations(_ response: String) -> Bool {
        let lower = response.lowercased()
        return GuardRailRules.citationKeywords.contains(where: { lower.contains($0) })
    }

    /// Check if response is giving specific medical advice (not just general information).
    /// Phrase list lives in GuardRailRules for the same bilingual reason as above.
    private func isMedicalAdvice(_ response: String) -> Bool {
        let lower = response.lowercased()
        return GuardRailRules.medicalAdvicePhrases.contains(where: { lower.contains($0) })
    }
    
    // MARK: - Response Modifiers
    
    /// Add reminder to include citations
    private func addCitationReminder(
        _ response: String, context: RetrievedContext?, vietnamese: Bool
    ) -> String {
        let citationNote = vietnamese ? """

        ⚠️ **Lưu ý quan trọng**: Thông tin y tế này cần được xác nhận với nhân viên y tế của bạn và dựa trên các nguồn y khoa đáng tin cậy.
        """ : """

        ⚠️ **Important**: This medical information should be verified with your healthcare provider and based on authoritative medical sources.
        """

        var result = response + citationNote

        if let sources = context?.sources, !sources.isEmpty {
            result += vietnamese ? "\n\n**Nguồn tài liệu:**\n" : "\n\n**Sources:**\n"
            for source in sources {
                let page = vietnamese ? "Trang \(source.page)" : "Page \(source.page)"
                result += "- \(source.title) (\(page))\n"
            }
        }

        return result
    }

    /// Add warning for low confidence
    private func addLowConfidenceWarning(_ response: String, vietnamese: Bool) -> String {
        let warning = vietnamese ? """

        ⚠️ **Giới hạn**: Tôi không có đủ thông tin y khoa đáng tin cậy để trả lời chắc chắn. Vui lòng tham khảo ý kiến nhân viên y tế để được tư vấn chính xác.
        """ : """

        ⚠️ **Limitation**: I don't have enough reliable medical context to provide a confident answer. Please consult with a healthcare professional for accurate medical advice.
        """
        return warning + response
    }

    /// Remove hallucinated claims from response
    private func removeHallucinatedClaims(_ response: String, vietnamese: Bool) -> String {
        let marker = vietnamese
            ? "[đã lược bỏ: thông tin chưa được kiểm chứng]"
            : "[removed: unverified claim]"
        var filtered = response
        for regex in Self.hallucinationRegexes {
            let range = NSRange(filtered.startIndex..<filtered.endIndex, in: filtered)
            filtered = regex.stringByReplacingMatches(in: filtered, options: [], range: range,
                                                      withTemplate: marker)
        }
        return filtered
    }

    /// Remove unsafe dosage information
    private func removeUnsafeDosage(_ response: String, vietnamese: Bool) -> String {
        let marker = vietnamese
            ? "[đã lược bỏ thông tin liều lượng - vui lòng hỏi nhân viên y tế]"
            : "[dosage information removed - consult healthcare provider]"
        var filtered = response
        for regex in Self.unsafeDosageRegexes {
            let range = NSRange(filtered.startIndex..<filtered.endIndex, in: filtered)
            filtered = regex.stringByReplacingMatches(in: filtered, options: [], range: range,
                                                      withTemplate: marker)
        }
        return filtered
    }
}
