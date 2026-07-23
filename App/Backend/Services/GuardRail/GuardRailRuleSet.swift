import Foundation

/// The externally-editable guardrail rule lists.
///
/// Rules used to be hard-coded string arrays in `GuardRailRules`. They now live in a bundled
/// `GuardRailRules.json` resource so they can be reviewed, versioned, and updated as data
/// rather than code. `GuardRailRuleStore` loads that JSON at launch and falls back to the
/// compiled-in `builtIn` set — per field — so a missing file, invalid JSON, or a partial
/// override can never silently disable an entire rule group.
///
/// Only the plaintext keyword/phrase lists are externalised here. The regex-based emergency
/// map and PII patterns remain in `GuardRailRules` (they carry enum/label structure and are
/// matched with `NSRegularExpression`, not naive substring checks).
struct GuardRailRuleSet: Codable {
    var medicalKeywords: [String]
    var dangerousPatterns: [String]
    var patientIntentPatterns: [String]
    var injectionPatterns: [String]
    var hallucinationIndicators: [String]
    var unsafeDosagePatterns: [String]
    var minMedicalConfidenceThreshold: Double

    // Per-field fallback: a JSON that omits (or empties) a field inherits the built-in
    // value for just that field, rather than wiping the rule group.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let b = GuardRailRuleSet.builtIn
        func list(_ key: CodingKeys, _ fallback: [String]) -> [String] {
            let v = (try? c.decodeIfPresent([String].self, forKey: key)) ?? nil
            return (v?.isEmpty == false) ? v! : fallback
        }
        medicalKeywords = list(.medicalKeywords, b.medicalKeywords)
        dangerousPatterns = list(.dangerousPatterns, b.dangerousPatterns)
        patientIntentPatterns = list(.patientIntentPatterns, b.patientIntentPatterns)
        injectionPatterns = list(.injectionPatterns, b.injectionPatterns)
        hallucinationIndicators = list(.hallucinationIndicators, b.hallucinationIndicators)
        unsafeDosagePatterns = list(.unsafeDosagePatterns, b.unsafeDosagePatterns)
        let threshold = (try? c.decodeIfPresent(Double.self, forKey: .minMedicalConfidenceThreshold)) ?? nil
        minMedicalConfidenceThreshold = threshold ?? b.minMedicalConfidenceThreshold
    }

    // Memberwise init for `builtIn` (the custom Decodable init above suppresses the synthesised one).
    init(
        medicalKeywords: [String],
        dangerousPatterns: [String],
        patientIntentPatterns: [String],
        injectionPatterns: [String],
        hallucinationIndicators: [String],
        unsafeDosagePatterns: [String],
        minMedicalConfidenceThreshold: Double
    ) {
        self.medicalKeywords = medicalKeywords
        self.dangerousPatterns = dangerousPatterns
        self.patientIntentPatterns = patientIntentPatterns
        self.injectionPatterns = injectionPatterns
        self.hallucinationIndicators = hallucinationIndicators
        self.unsafeDosagePatterns = unsafeDosagePatterns
        self.minMedicalConfidenceThreshold = minMedicalConfidenceThreshold
    }
}

/// Loads the effective rule set once, preferring the bundled JSON and falling back to built-in.
enum GuardRailRuleStore {
    static let current: GuardRailRuleSet = load()

    private static func load() -> GuardRailRuleSet {
        guard let url = Bundle.main.url(forResource: "GuardRailRules", withExtension: "json") else {
            print("GuardRailRuleStore: GuardRailRules.json not in bundle — using built-in rules")
            return .builtIn
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(GuardRailRuleSet.self, from: data)
        } catch {
            print("GuardRailRuleStore: failed to load GuardRailRules.json (\(error)) — using built-in rules")
            return .builtIn
        }
    }
}

extension GuardRailRuleSet {
    /// Compiled-in fallback. Must stay a complete, self-sufficient rule set: it is what ships
    /// if the JSON is ever missing or corrupt. Keep in sync with `GuardRailRules.json`.
    static let builtIn = GuardRailRuleSet(
        medicalKeywords: [
            // Vietnamese medical terms
            "triệu chứng", "bệnh", "đau", "viêm", "nhiễm", "phẫu thuật", "mổ", "vết",
            "mủ", "sốt", "chảy máu", "buồn nôn", "nôn", "tiêu chảy", "táo bón",
            "huyết áp", "tim", "phổi", "gan", "thận", "dạ dày", "ruột",
            "thuốc", "liều", "điều trị", "khỏe", "sức khỏe", "bác sĩ", "y tế",
            "hồi phục", "vận động", "ăn uống", "sinh hoạt", "hạn chế",
            // Vietnamese nutrition/lifestyle terms
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
            // English nutrition/lifestyle terms
            "eat", "food", "drink", "meal", "nutrition", "nutrient", "mineral",
            "calorie", "weight", "hydration", "water", "fruit", "vegetable", "protein",
            "carbohydrate", "fiber", "supplement", "appetite", "avoid eating", "should eat",
            "what to eat", "foods to", "dietary",
            // Stoma / colorectal / urology
            "stoma", "colostomy", "ileostomy", "urostomy", "ostomy",
            "bowel", "colon", "colorectal", "rectal", "rectum",
            "cancer", "tumor", "malignant", "carcinoma",
            "catheter", "catheterization", "urinary", "urine", "diversion",
            "stent", "colonic", "reversal", "pouch", "bag", "output",
            "continent", "incontinent", "appliance", "wafer", "flange",
            "peristomal", "stomal", "effluent",
        ],
        dangerousPatterns: [
            "tự tử", "cách để chết", "cách chết", "cách tự sát", "uống thuốc để chết",
            "treo cổ", "đâm thương", "cắt cổ tay", "tước đoạt mạng sống",
            "thuốc độc", "chất độc", "cách để độc", "đánh độc", "cách độc người",
            "làm malware", "viết virus", "hướng dẫn bom", "cách làm bom",
            "synthesis bomb", "make cocaine", "produce fentanyl", "drug synthesis",
            "how to commit suicide", "how to kill myself", "methods of self-harm",
            "lethal dose", "overdose amount",
        ],
        patientIntentPatterns: [
            "can i have", "can i eat", "can i drink", "can i take", "can i use",
            "should i eat", "should i drink", "should i take", "should i avoid",
            "is it okay to", "is it safe to", "is it okay if", "is it ok to",
            "is it good for", "is it bad for", "is it healthy",
            "what can i eat", "what should i eat", "what to eat", "what to drink",
            "what foods", "what food", "foods to avoid", "foods to eat",
            "good for my", "bad for my", "safe for me",
            "tôi có thể ăn", "tôi có thể uống", "có được ăn", "có nên ăn",
            "có được uống", "có nên uống", "nên ăn gì", "nên uống gì",
            "ăn gì tốt", "uống gì tốt", "có hại không", "có tốt không",
            "có được dùng", "tôi nên ăn", "tôi nên uống", "kiêng gì",
            "có ảnh hưởng không", "có tốt cho", "có hại cho",
        ],
        injectionPatterns: [
            "ignore previous instruction",
            "you are no longer",
            "show system prompt",
            "show me the prompt",
            "reveal instructions",
            "act as dan",
            "forget your role",
            "break character",
            "bypass safety",
            "deactivate safeguard",
            "disable guardrail",
        ],
        hallucinationIndicators: [
            "definitely cure",
            "100% effective",
            "take \\d+ pill",
            "inject \\d+ mg",
            "will definitely",
            "guaranteed to",
            "miraculous",
            "instant relief",
        ],
        unsafeDosagePatterns: [
            "ibuprofen.*1000",
            "paracetamol.*5000",
            "aspirin.*2000",
            "take all",
            "maximum dose",
        ],
        minMedicalConfidenceThreshold: 0.65
    )
}
