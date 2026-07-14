import Foundation

// MARK: - GuardRail Results

enum GuardRailStatus {
    case allowed
    case blocked(reason: String)
}

struct InputGuardRailResult {
    let status: GuardRailStatus
    let originalQuery: String
    let sanitizedQuery: String?
    let violations: [String]
    
    init(status: GuardRailStatus, originalQuery: String, sanitizedQuery: String? = nil, violations: [String] = []) {
        self.status = status
        self.originalQuery = originalQuery
        self.sanitizedQuery = sanitizedQuery
        self.violations = violations
    }
}

struct OutputGuardRailResult {
    let status: GuardRailStatus
    let originalResponse: String
    let filteredResponse: String?
    let issues: [String]
    let confidenceScore: Double

    init(status: GuardRailStatus, originalResponse: String, filteredResponse: String? = nil, issues: [String] = [], confidenceScore: Double = 1.0) {
        self.status = status
        self.originalResponse = originalResponse
        self.filteredResponse = filteredResponse
        self.issues = issues
        self.confidenceScore = confidenceScore
    }
}

struct RetrievedContext {
    let chunks: [ContextChunk]
    let confidenceScore: Double
    let sources: [MedicalSource]
    
    init(chunks: [ContextChunk], confidenceScore: Double, sources: [MedicalSource] = []) {
        self.chunks = chunks
        self.confidenceScore = confidenceScore
        self.sources = sources
    }
}

struct ContextChunk {
    let id: String
    let content: String
    let section: String
    let sourceID: String
    let relevanceScore: Double
    
    init(id: String, content: String, section: String, sourceID: String, relevanceScore: Double) {
        self.id = id
        self.content = content
        self.section = section
        self.sourceID = sourceID
        self.relevanceScore = relevanceScore
    }
}

struct EmergencyDetectionResult {
    let isEmergency: Bool
    let symptomType: EmergencySymptomType?
    let recommendation: String?
    
    init(isEmergency: Bool, symptomType: EmergencySymptomType? = nil, recommendation: String? = nil) {
        self.isEmergency = isEmergency
        self.symptomType = symptomType
        self.recommendation = recommendation
    }
}

enum EmergencySymptomType: String {
    case chestPain = "chest_pain"
    case difficulty_breathing = "difficulty_breathing"
    case seizure = "seizure"
    case suicidal_ideation = "suicidal_ideation"
    case stroke_symptom = "stroke_symptom"
    case severe_bleeding = "severe_bleeding"
    case loss_of_consciousness = "loss_of_consciousness"
}
