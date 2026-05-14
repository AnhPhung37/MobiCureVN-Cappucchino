import Foundation

/// Query Refiner: rewrites user queries for better retrieval
/// Steps:
/// 1. Normalize Vietnamese → English medical terminology
/// 2. Expand abbreviations
/// 3. Rewrite into standardized medical search terms
final class QueryRefiner {
    
    init() {}
    
    /// Rewrite query for better retrieval
    func refineQuery(_ userQuery: String) -> String {
        var refined = userQuery
        
        // Step 1: Normalize Vietnamese medical terms to English
        refined = normalizeVietnameseMedical(refined)
        
        // Step 2: Expand common abbreviations
        refined = expandAbbreviations(refined)
        
        // Step 3: Add medical context/keywords
        refined = enrichWithMedicalContext(refined)
        
        return refined
    }
    
    // MARK: - Private Refinement Steps
    
    /// Vietnamese → English medical term mapping
    private func normalizeVietnameseMedical(_ query: String) -> String {
        let vietnameseToEnglish: [String: String] = [
            // Symptoms
            "vết mổ": "surgical wound incision",
            "đau": "pain",
            "sốt": "fever",
            "buồn nôn": "nausea",
            "nôn": "vomit",
            "tiêu chảy": "diarrhea",
            "táo bón": "constipation",
            "chảy máu": "bleeding",
            "khó thở": "difficulty breathing",
            "đau ngực": "chest pain",
            "co giật": "seizure",
            "chóng mặt": "dizziness",
            "mệt mỏi": "fatigue",
            "yếu": "weakness",
            
            // Conditions
            "viêm": "inflammation",
            "nhiễm trùng": "infection",
            "nhiễm": "infection",
            "bệnh": "disease",
            "ung thư": "cancer",
            "tiểu đường": "diabetes",
            "huyết áp cao": "hypertension",
            "tim": "heart",
            "phổi": "lung",
            "gan": "liver",
            "thận": "kidney",
            "dạ dày": "stomach",
            "ruột": "intestine",
            
            // Treatment
            "phẫu thuật": "surgery",
            "mổ": "surgery",
            "thuốc": "medication medicine",
            "liều": "dose dosage",
            "điều trị": "treatment",
            "chữa trị": "treatment",
            "hồi phục": "recovery",
            "chăm sóc": "care",
            "vận động": "exercise movement",
            "ăn uống": "diet nutrition",
            
            // General
            "bác sĩ": "physician doctor",
            "y tế": "medical health",
            "sức khỏe": "health wellness",
            "sau phẫu thuật": "post-operative post-surgery",
            "trước phẫu thuật": "pre-operative pre-surgery"
        ]
        
        var result = query.lowercased()
        for (vietnamese, english) in vietnameseToEnglish {
            result = result.replacingOccurrences(of: vietnamese, with: english, options: .caseInsensitive)
        }
        
        return result
    }
    
    /// Expand common abbreviations
    private func expandAbbreviations(_ query: String) -> String {
        let abbreviations: [String: String] = [
            " rx ": " prescription treatment ",
            " dx ": " diagnosis ",
            " tx ": " treatment ",
            " sx ": " symptom ",
            " htn ": " hypertension high blood pressure ",
            " dm ": " diabetes mellitus ",
            " cad ": " coronary artery disease ",
            " copd ": " chronic obstructive pulmonary disease ",
            " uti ": " urinary tract infection ",
            " opi ": " post operative infection ",
            " bp ": " blood pressure ",
            " hr ": " heart rate ",
            " temp ": " temperature ",
            " mg ": " milligram ",
            " ml ": " milliliter "
        ]
        
        var result = query.lowercased()
        for (abbrev, expanded) in abbreviations {
            result = result.replacingOccurrences(of: abbrev, with: " \(expanded) ", options: .caseInsensitive)
        }
        
        return result
    }
    
    /// Enrich query with medical search context
    private func enrichWithMedicalContext(_ query: String) -> String {
        // Add contextual keywords to help retrieval
        var enriched = query
        
        // If query mentions pain, add symptom context
        if query.lowercased().contains("pain") || query.lowercased().contains("đau") {
            enriched += " symptoms management treatment"
        }
        
        // If query mentions medication, add dosage/safety context
        if query.lowercased().contains("medication") || query.lowercased().contains("drug") || query.lowercased().contains("thuốc") {
            enriched += " dosage safety contraindications side effects"
        }
        
        // If query mentions recovery/post-op, add rehabilitation context
        if query.lowercased().contains("recovery") || query.lowercased().contains("post") || query.lowercased().contains("hồi phục") {
            enriched += " rehabilitation exercises activity guidelines"
        }
        
        // If query mentions infection, add prevention context
        if query.lowercased().contains("infection") || query.lowercased().contains("nhiễm") {
            enriched += " prevention signs symptoms care"
        }
        
        return enriched
    }
}

/// Query Rewrite Service: standalone async version
final class QueryRewriteService {
    private let refiner: QueryRefiner
    
    init() {
        self.refiner = QueryRefiner()
    }
    
    /// Async query rewriting (can integrate LLM-based rewriting later)
    func rewrite(userQuery: String) async -> String {
        // For MVP: use rule-based refiner
        // Future: use local LLM for sophisticated rewriting
        return refiner.refineQuery(userQuery)
    }
}
