import Foundation

// MARK: - GuardRail Rules

struct GuardRailRules {

    // MARK: - Semantic Medical Anchors (NLEmbedding)

    /// Anchor phrases compared against user queries via NLEmbedding cosine distance.
    /// Seeded with the built-in fallback set at launch; replaced with dataset-derived phrases
    /// once MedicalAnchorLoader finishes downloading the Kaggle medical-text corpus.
    /// `nonisolated(unsafe)` is safe here: written exactly once at app startup before any
    /// queries arrive, then only read afterwards.
    nonisolated(unsafe) static var medicalAnchors: [String] = MedicalAnchorLoader.builtInAnchors

    static func updateMedicalAnchors(_ anchors: [String]) {
        guard !anchors.isEmpty else { return }
        medicalAnchors = anchors
    }

    // MARK: - Input Rules

    /// Rule Group 1: Domain Filter — only medical queries
    static let medicalKeywords = Set([
        // Vietnamese medical terms
        "triệu chứng", "bệnh", "đau", "viêm", "nhiễm", "phẫu thuật", "mổ", "vết",
        "mủ", "sốt", "chảy máu", "buồn nôn", "nôn", "tiêu chảy", "táo bón",
        "huyết áp", "tim", "phổi", "gan", "thận", "dạ dày", "ruột",
        "thuốc", "liều", "điều trị", "khỏe", "sức khỏe", "bác sĩ", "y tế",
        "hồi phục", "vận động", "ăn uống", "sinh hoạt", "hạn chế",

        // Vietnamese nutrition/lifestyle terms patients commonly ask
        "ăn", "uống", "thức ăn", "thực phẩm", "dinh dưỡng", "bữa ăn",
        "calo", "cân nặng", "vitamin", "nước", "rau", "trái cây",
        "chất đạm", "chất béo", "tinh bột", "chế độ ăn", "tránh ăn",
        "nên ăn", "không nên ăn", "kiêng", "bổ sung",

        // English medical terms
        "symptom", "disease", "pain", "infection", "inflammation", "surgery", "surgical",
        "wound", "incision", "scar", "fever", "bleeding", "nausea", "vomit", "diarrhea", "constipation",
        "blood pressure", "heart", "lung", "liver", "kidney", "stomach", "intestine",
        "medicine", "drug", "dose", "treatment", "recovery", "exercise", "diet",
        "physician", "doctor", "health", "medical", "postoperative", "post-op", "healing",

        // English nutrition/lifestyle terms patients commonly ask
        "eat", "food", "drink", "meal", "nutrition", "nutrient", "vitamin", "mineral",
        "calorie", "weight", "hydration", "water", "fruit", "vegetable", "protein",
        "carbohydrate", "fiber", "supplement", "appetite", "avoid eating", "should eat",
        "what to eat", "foods to", "dietary",
        
        // Stoma / colorectal / urology — core domain terms for this app
        "stoma", "colostomy", "ileostomy", "urostomy", "ostomy",
        "bowel", "colon", "colorectal", "rectal", "rectum",
        "cancer", "tumor", "malignant", "carcinoma",
        "catheter", "catheterization", "urinary", "urine", "diversion",
        "stent", "colonic", "reversal", "pouch", "bag", "output",
        "continent", "incontinent", "appliance", "wafer", "flange",
        "peristomal", "stomal", "effluent"
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
    
    /// Rule Group 1b: Patient intent patterns — health-related phrasing even without explicit medical vocab.
    /// Covers lifestyle/diet questions patients ask without using clinical language.
    static let patientIntentPatterns = [
        // English — permission/safety questions
        "can i have", "can i eat", "can i drink", "can i take", "can i use",
        "should i eat", "should i drink", "should i take", "should i avoid",
        "is it okay to", "is it safe to", "is it okay if", "is it ok to",
        "is it good for", "is it bad for", "is it healthy",
        "what can i eat", "what should i eat", "what to eat", "what to drink",
        "what foods", "what food", "foods to avoid", "foods to eat",
        "good for my", "bad for my", "safe for me",

        // Vietnamese — common patient phrasing
        "tôi có thể ăn", "tôi có thể uống", "có được ăn", "có nên ăn",
        "có được uống", "có nên uống", "nên ăn gì", "nên uống gì",
        "ăn gì tốt", "uống gì tốt", "có hại không", "có tốt không",
        "có được dùng", "tôi nên ăn", "tôi nên uống", "kiêng gì",
        "có ảnh hưởng không", "có tốt cho", "có hại cho"
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
        "can't breathe": .difficultyBreathing,
        "difficulty breathing": .difficultyBreathing,
        "khó thở": .difficultyBreathing,
        "thở không được": .difficultyBreathing,
        "shortness of breath": .difficultyBreathing,
        
        // Seizure
        "seizure": .seizure,
        "co giật": .seizure,
        "convulsion": .seizure,
        
        // Suicidal ideation
        "want to die": .suicidalIdeation,
        "kill myself": .suicidalIdeation,
        "muốn chết": .suicidalIdeation,
        "tự tử": .suicidalIdeation,
        "not worth living": .suicidalIdeation,
        
        // Stroke symptoms
        "face drooping": .strokeSymptom,
        "arm weakness": .strokeSymptom,
        "speech difficulty": .strokeSymptom,
        "xệch mặt": .strokeSymptom,
        "yếu tay": .strokeSymptom,
        "nói không rõ": .strokeSymptom,
        
        // Severe bleeding
        "heavy bleeding": .severeBleeding,
        "chảy máu nhiều": .severeBleeding,
        "can't stop bleeding": .severeBleeding,
        
        // Loss of consciousness
        "lost consciousness": .lossOfConsciousness,
        "fainting": .lossOfConsciousness,
        "mất ý thức": .lossOfConsciousness,
        "bất tỉnh": .lossOfConsciousness
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
        
        .difficultyBreathing: "🚨 **EMERGENCY**: Difficulty breathing is a medical emergency. CALL 119 or go to the nearest emergency room NOW. Do not delay. Difficulty breathing requires immediate medical attention.",
        
        .seizure: "🚨 **EMERGENCY**: Seizures are a medical emergency. CALL 119 immediately. Keep the person safe, do not restrain them. Emergency medical attention is required.",
        
        .suicidalIdeation: "🚨 **CRISIS SUPPORT**: If you're having thoughts of suicide, please reach out for help immediately:\n\n**Vietnam Crisis Hotline**: 1925\n**International**: 988 (US), +44 (UK)\n\nTalk to someone you trust, or contact emergency services. Your life matters.",
        
        .strokeSymptom: "🚨 **EMERGENCY**: Stroke symptoms require immediate emergency care. CALL 119 right away. Every minute counts. Do not wait.",
        
        .severeBleeding: "🚨 **EMERGENCY**: Severe bleeding requires immediate emergency care. CALL 119 or go to the nearest emergency room NOW. Apply pressure to stop bleeding while waiting for help.",
        
        .lossOfConsciousness: "🚨 **EMERGENCY**: Loss of consciousness is a medical emergency. CALL 119 immediately. Ensure the person is in a safe position."
    ]
}
