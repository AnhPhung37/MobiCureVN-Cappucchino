import Foundation

/// Emergency Detector: identifies critical health situations
final class EmergencyDetector {
    
    init() {}
    
    /// Detect emergency in user query
    func detect(query: String) -> EmergencyDetectionResult {
        let lower = query.lowercased()
        
        // Check all emergency symptom patterns
        for (pattern, symptomType) in GuardRailRules.emergencySymptomPatterns {
            if lower.contains(pattern.lowercased()) {
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
