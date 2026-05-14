import Foundation

// MARK: - GuardRail Rules

struct GuardRailRules {
    
    // MARK: - Input Rules
    
    /// Rule Group 1: Domain Filter — only medical queries
    static let medicalKeywords = Set([
        // Vietnamese medical terms
        "triệu chứng", "bệnh", "đau", "viêm", "nhiễm", "phẫu thuật", "mổ", "vết",
        "mủ", "sốt", "chảy máu", "buồn nôn", "nôn", "tiêu chảy", "táo bón",
        "huyết áp", "tim", "phổi", "gan", "thận", "dạ dày", "ruột",
        "thuốc", "liều", "điều trị", "khỏe", "sức khỏe", "bác sĩ", "y tế",
        "hồi phục", "vận động", "ăn uống", "sinh hoạt", "hạn chế",
        
        // English medical terms
        "symptom", "disease", "pain", "infection", "inflammation", "surgery",
        "wound", "fever", "bleeding", "nausea", "vomit", "diarrhea", "constipation",
        "blood pressure", "heart", "lung", "liver", "kidney", "stomach", "intestine",
        "medicine", "drug", "dose", "treatment", "recovery", "exercise", "diet",
        "physician", "doctor", "health", "medical"
    ])
    
    /// Rule Group 2: Hard-block dangerous requests
    static let dangerousPatterns = [
        // Suicide/self-harm (Vietnamese)
        "tự tử", "cách để chết", "cách chết", "cách tự sát", "uống thuốc để chết",
        "treo cổ", "đâm thương", "cắt cổ tay", "tước đoạt mạng sống",
        
        // Poison/toxic (Vietnamese)
        "thuốc độc", "chất độc", "cách để độc", "đánh độc", "cách độc người",
        
        // Illegal synthesis (Vietnamese + English)
        "làm malware", "viết virus", "hướng dẫn bom", "cách làm bom",
        "synthesis bomb", "make cocaine", "produce fentanyl", "drug synthesis",
        
        // Self-harm (English)
        "how to commit suicide", "how to kill myself", "methods of self-harm",
        "lethal dose", "overdose amount"
    ]
    
    /// Rule Group 3: Prompt injection / jailbreak patterns
    static let injectionPatterns = [
        "ignore previous instruction",
        "you are no longer",
        "show system prompt",
        "show me the prompt",
        "reveal instructions",
        "act as dan",
        "act as a",
        "forget your role",
        "break character",
        "bypass safety",
        "deactivate safeguard",
        "disable guardrail"
    ]
    
    // MARK: - Output Rules
    
    /// Confidence threshold for medical advice (0.0 - 1.0)
    static let minMedicalConfidenceThreshold: Double = 0.65
    
    /// Patterns indicating hallucinated advice
    static let hallucinationIndicators = [
        "definitely cure",
        "100% effective",
        "take \\d+ pill",
        "inject \\d+ mg",
        "will definitely",
        "guaranteed to",
        "miraculous",
        "instant relief"
    ]
    
    /// Unsafe dosage patterns to flag
    static let unsafeDosagePatterns = [
        "ibuprofen.*1000", // > 1000mg
        "paracetamol.*5000", // > 5000mg
        "aspirin.*2000", // > 2000mg
        "take all",
        "maximum dose"
    ]
    
    // MARK: - Emergency Symptoms
    
    static let emergencySymptomPatterns: [String: EmergencySymptomType] = [
        // Chest pain
        "chest pain": .chestPain,
        "đau ngực": .chestPain,
        "pressure in chest": .chestPain,
        
        // Difficulty breathing
        "can't breathe": .difficulty_breathing,
        "difficulty breathing": .difficulty_breathing,
        "khó thở": .difficulty_breathing,
        "thở không được": .difficulty_breathing,
        "shortness of breath": .difficulty_breathing,
        
        // Seizure
        "seizure": .seizure,
        "co giật": .seizure,
        "convulsion": .seizure,
        
        // Suicidal ideation
        "want to die": .suicidal_ideation,
        "kill myself": .suicidal_ideation,
        "muốn chết": .suicidal_ideation,
        "tự tử": .suicidal_ideation,
        "not worth living": .suicidal_ideation,
        
        // Stroke symptoms
        "face drooping": .stroke_symptom,
        "arm weakness": .stroke_symptom,
        "speech difficulty": .stroke_symptom,
        "xệch mặt": .stroke_symptom,
        "yếu tay": .stroke_symptom,
        "nói không rõ": .stroke_symptom,
        
        // Severe bleeding
        "heavy bleeding": .severe_bleeding,
        "chảy máu nhiều": .severe_bleeding,
        "can't stop bleeding": .severe_bleeding,
        
        // Loss of consciousness
        "lost consciousness": .loss_of_consciousness,
        "fainting": .loss_of_consciousness,
        "mất ý thức": .loss_of_consciousness,
        "bất tỉnh": .loss_of_consciousness
    ]
    
    // MARK: - PII Patterns
    
    static let piiPatterns: [(pattern: String, label: String)] = [
        // Phone (Vietnamese format +84 or 0)
        ("(\\+84|0)(\\d{1,2})\\d{3,4}\\d{4}", "PHONE"),
        
        // CCCD/ID (12 digits)
        ("\\d{12}", "CCCD"),
        
        // Email
        ("[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}", "EMAIL"),
        
        // Address patterns (heuristic)
        ("(đường|phố|phường|quận|huyện|tỉnh)\\s+[^,\\.]+", "ADDRESS"),
        
        // Insurance/ID-like patterns
        ("(BHYT|BHXH|BH)\\s*[A-Z0-9]{6,}", "INSURANCE_ID")
    ]
}

// MARK: - Emergency Response Templates

struct EmergencyResponses {
    static let templates: [EmergencySymptomType: String] = [
        .chestPain: "🚨 **EMERGENCY**: Chest pain can be a sign of a serious medical condition. CALL EMERGENCY SERVICES (119 in Vietnam) or visit the nearest emergency room immediately. Do not wait. This requires immediate professional medical evaluation.",
        
        .difficulty_breathing: "🚨 **EMERGENCY**: Difficulty breathing is a medical emergency. CALL 119 or go to the nearest emergency room NOW. Do not delay. Difficulty breathing requires immediate medical attention.",
        
        .seizure: "🚨 **EMERGENCY**: Seizures are a medical emergency. CALL 119 immediately. Keep the person safe, do not restrain them. Emergency medical attention is required.",
        
        .suicidal_ideation: "🚨 **CRISIS SUPPORT**: If you're having thoughts of suicide, please reach out for help immediately:\n\n**Vietnam Crisis Hotline**: 1925\n**International**: 988 (US), +44 (UK)\n\nTalk to someone you trust, or contact emergency services. Your life matters.",
        
        .stroke_symptom: "🚨 **EMERGENCY**: Stroke symptoms require immediate emergency care. CALL 119 right away. Every minute counts. Do not wait.",
        
        .severe_bleeding: "🚨 **EMERGENCY**: Severe bleeding requires immediate emergency care. CALL 119 or go to the nearest emergency room NOW. Apply pressure to stop bleeding while waiting for help.",
        
        .loss_of_consciousness: "🚨 **EMERGENCY**: Loss of consciousness is a medical emergency. CALL 119 immediately. Ensure the person is in a safe position."
    ]
}
