import Foundation

// MARK: - GuardRail Rules

struct GuardRailRules {

    // MARK: - Semantic Medical Anchors (NLEmbedding)

    /// Anchor phrases compared against user queries via NLEmbedding cosine distance.
    /// Seeded with the built-in fallback set at launch, then replaced with dataset-derived
    /// phrases when MedicalAnchorLoader finishes downloading the Kaggle corpus — which can
    /// happen *after* queries start arriving. Reads and that one late write are therefore
    /// serialized by `medicalAnchorsLock`; `nonisolated(unsafe)` only opts the stored
    /// property out of Swift's actor-isolation checking, the lock provides the real safety.
    private nonisolated(unsafe) static var _medicalAnchors: [String] = MedicalAnchorLoader.builtInAnchors
    private static let medicalAnchorsLock = NSLock()

    /// Thread-safe snapshot of the anchor phrases. Read on the generation task while the
    /// Kaggle download may still be writing on a startup task, so access is lock-guarded.
    static var medicalAnchors: [String] {
        medicalAnchorsLock.lock()
        defer { medicalAnchorsLock.unlock() }
        return _medicalAnchors
    }

    static func updateMedicalAnchors(_ anchors: [String]) {
        guard !anchors.isEmpty else { return }
        medicalAnchorsLock.lock()
        _medicalAnchors = anchors
        medicalAnchorsLock.unlock()
    }

    // MARK: - Input Rules
    //
    // The plaintext keyword/phrase lists below are loaded from the bundled
    // `GuardRailRules.json` (via `GuardRailRuleStore`), with a compiled-in fallback in
    // `GuardRailRuleSet.builtIn`. Matching goes through `GuardRailNormalizer`, so it is
    // insensitive to case, diacritics, width, punctuation, and spacing — list patterns in
    // their natural form. Pre-normalised variants are cached here so the fold runs once at
    // launch rather than per query.

    /// Rule Group 1: Domain Filter — only medical queries. Matched with lowercased substring
    /// (see InputGuardRail): diacritic folding is intentionally NOT applied here because short
    /// Vietnamese syllables (e.g. "ăn" → "an") would then match ubiquitous non-medical words
    /// like "an toàn" and effectively disable the filter. Evasion resistance is reserved for
    /// the blocklists below, where it matters.
    static let medicalKeywords = Set(GuardRailRuleStore.current.medicalKeywords)

    /// Rule Group 2: Hard-block dangerous requests.
    static let dangerousPatterns = GuardRailRuleStore.current.dangerousPatterns

    /// Pre-normalised blocklist for dangerous requests: (raw, canonical, compact).
    /// The compact (de-spaced) form catches character-spacing evasion ("t ự t ử").
    static let dangerousBlocklist: [(raw: String, canonical: String, compact: String)] =
        dangerousPatterns.map { ($0, GuardRailNormalizer.canonical($0), GuardRailNormalizer.compact($0)) }

    /// Rule Group 1b: Patient intent patterns — health-related phrasing without explicit
    /// medical vocab (lifestyle/diet questions patients ask in plain language).
    static let patientIntentPatterns = GuardRailRuleStore.current.patientIntentPatterns

    /// Rule Group 3: Prompt injection / jailbreak patterns.
    /// (The overly-broad "act as a" was removed — it false-blocked benign phrasing like
    /// "can the nurse act as a caregiver"; "act as dan" is retained.)
    static let injectionPatterns = GuardRailRuleStore.current.injectionPatterns

    /// Pre-normalised blocklist for injection attempts: (raw, canonical, compact).
    static let injectionBlocklist: [(raw: String, canonical: String, compact: String)] =
        injectionPatterns.map { ($0, GuardRailNormalizer.canonical($0), GuardRailNormalizer.compact($0)) }

    // MARK: - Output Rules

    /// Confidence threshold for medical advice (0.0 - 1.0).
    static let minMedicalConfidenceThreshold: Double = GuardRailRuleStore.current.minMedicalConfidenceThreshold

    /// Regex patterns indicating hallucinated advice (matched with NSRegularExpression).
    static let hallucinationIndicators = GuardRailRuleStore.current.hallucinationIndicators

    /// Regex patterns for unsafe dosage (matched with NSRegularExpression).
    static let unsafeDosagePatterns = GuardRailRuleStore.current.unsafeDosagePatterns
    
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
