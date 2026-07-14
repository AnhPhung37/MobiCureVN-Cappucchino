import Foundation

/// Emergency Detector: identifies critical health situations
final class EmergencyDetector {

    /// Precompiled, boundary-aware matchers, built once from the rule table.
    /// Word boundaries (`(?<!letter/digit) … (?!letter/digit)`) stop a phrase from matching
    /// *inside* a larger word; a genuine standalone occurrence still triggers, which is
    /// intentional for a safety filter (favour recall). Works for Vietnamese and English.
    private static let matchers: [(regex: NSRegularExpression, symptomType: EmergencySymptomType)] =
        GuardRailRules.emergencySymptomPatterns.compactMap { pattern, symptomType in
            let escaped = NSRegularExpression.escapedPattern(for: pattern.lowercased())
            let bounded = "(?<![\\p{L}\\p{N}])\(escaped)(?![\\p{L}\\p{N}])"
            guard let regex = try? NSRegularExpression(pattern: bounded, options: [.caseInsensitive]) else { return nil }
            return (regex, symptomType)
        }

    nonisolated init() {}

    /// Detect emergency in user query
    func detect(query: String) -> EmergencyDetectionResult {
        let lower = query.lowercased()
        let range = NSRange(lower.startIndex..<lower.endIndex, in: lower)

        for (regex, symptomType) in Self.matchers {
            if regex.firstMatch(in: lower, options: [], range: range) != nil {
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
}
