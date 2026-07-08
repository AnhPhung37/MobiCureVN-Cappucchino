import Foundation

/// Query Refiner: rewrites user queries for better retrieval
/// Steps:
/// 1. Normalize Vietnamese → English medical terminology
/// 2. Expand abbreviations
/// 3. Rewrite into standardized medical search terms
struct RefinedQuery {
    let baseQuery: String
    let enrichedTerms: [String]
}

final class QueryRefiner {

    init() {}

    /// Rewrite query for better retrieval
    func refineQuery(_ userQuery: String) -> RefinedQuery {
        var refined = userQuery

        // Step 1: Normalize Vietnamese medical terms to English
        refined = normalizeVietnameseMedical(refined)

        // Step 2: Expand common abbreviations
        refined = expandAbbreviations(refined)

        let normalized = normalizeWhitespace(refined)
        let enrichedTerms = enrichWithMedicalContext(normalized)

        return RefinedQuery(baseQuery: normalized, enrichedTerms: enrichedTerms)
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
        // Longest keys first — prevents shorter substrings (e.g. "nôn") from corrupting longer matches ("buồn nôn")
        for (vietnamese, english) in vietnameseToEnglish.sorted(by: { $0.key.count > $1.key.count }) {
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
    private func enrichWithMedicalContext(_ query: String) -> [String] {
        var terms: [String] = []
        let lower = query.lowercased()

        if lower.contains("pain") || lower.contains("đau") {
            terms.append(contentsOf: ["symptoms", "management", "treatment"])
        }

        if lower.contains("medication") || lower.contains("drug") || lower.contains("thuốc") {
            terms.append(contentsOf: ["dosage", "safety", "contraindications", "side", "effects"])
        }

        if lower.contains("recovery") || lower.contains("post") || lower.contains("hồi phục") {
            terms.append(contentsOf: ["rehabilitation", "exercises", "activity", "guidelines"])
        }

        if lower.contains("infection") || lower.contains("nhiễm") {
            terms.append(contentsOf: ["prevention", "signs", "symptoms", "care"])
        }

        var seen = Set<String>()
        return terms.filter { seen.insert($0).inserted }
    }

    private func normalizeWhitespace(_ text: String) -> String {
        return text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
