import XCTest
@testable import MobiCureVN

/// Tests for EmergencyDetector — verifies all critical health situation patterns are detected.
/// A new build passes if:
///   - All emergency symptom types (chest pain, breathing, seizure, etc.) are detected
///   - Vietnamese emergency phrases are detected
///   - Normal queries return isEmergency = false
///   - Emergency responses contain correct hotline numbers
@MainActor
final class EmergencyDetectorTests: XCTestCase {

    private var sut: EmergencyDetector!

    override func setUp() {
        super.setUp()
        sut = EmergencyDetector()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - Non-Emergency Baseline

    func testNormalQueryIsNotEmergency() {
        let result = sut.detect(query: "What diet should I follow after colorectal surgery?")
        XCTAssertFalse(result.isEmergency)
        XCTAssertNil(result.symptomType)
        XCTAssertNil(result.recommendation)
    }

    func testEmptyQueryIsNotEmergency() {
        let result = sut.detect(query: "")
        XCTAssertFalse(result.isEmergency)
    }

    // MARK: - Chest Pain

    func testDetectsChestPainEnglish() {
        let result = sut.detect(query: "I have severe chest pain right now")
        XCTAssertTrue(result.isEmergency)
        XCTAssertEqual(result.symptomType, .chestPain)
        XCTAssertNotNil(result.recommendation)
    }

    func testDetectsChestPainVietnamese() {
        let result = sut.detect(query: "Tôi đang bị đau ngực rất nặng")
        XCTAssertTrue(result.isEmergency)
        XCTAssertEqual(result.symptomType, .chestPain)
    }

    func testChestPainRecommendationContainsEmergencyNumber() {
        let result = sut.detect(query: "chest pain")
        XCTAssertTrue(result.recommendation?.contains("119") ?? false,
                      "Chest pain response should include Vietnam emergency number 119")
    }

    // MARK: - Difficulty Breathing

    func testDetectsDifficultyBreathingEnglish() {
        let result = sut.detect(query: "I have difficulty breathing and shortness of breath")
        XCTAssertTrue(result.isEmergency)
        XCTAssertEqual(result.symptomType, .difficultyBreathing)
    }

    func testDetectsCantBreathe() {
        let result = sut.detect(query: "I can't breathe properly")
        XCTAssertTrue(result.isEmergency)
        XCTAssertEqual(result.symptomType, .difficultyBreathing)
    }

    func testDetectsDifficultyBreathingVietnamese() {
        let result = sut.detect(query: "Tôi khó thở, thở không được")
        XCTAssertTrue(result.isEmergency)
        XCTAssertEqual(result.symptomType, .difficultyBreathing)
    }

    func testBreathingRecommendationContainsEmergencyNumber() {
        let result = sut.detect(query: "difficulty breathing")
        XCTAssertTrue(result.recommendation?.contains("119") ?? false)
    }

    // MARK: - Seizure

    func testDetectsSeizureEnglish() {
        let result = sut.detect(query: "The patient had a seizure and is convulsing")
        XCTAssertTrue(result.isEmergency)
        XCTAssertEqual(result.symptomType, .seizure)
    }

    func testDetectsConvulsion() {
        let result = sut.detect(query: "convulsion started suddenly")
        XCTAssertTrue(result.isEmergency)
        XCTAssertEqual(result.symptomType, .seizure)
    }

    func testDetectsSeizureVietnamese() {
        let result = sut.detect(query: "Bệnh nhân đang bị co giật")
        XCTAssertTrue(result.isEmergency)
        XCTAssertEqual(result.symptomType, .seizure)
    }

    // MARK: - Suicidal Ideation

    func testDetectsWantToDie() {
        let result = sut.detect(query: "I want to die, I can't cope anymore")
        XCTAssertTrue(result.isEmergency)
        XCTAssertEqual(result.symptomType, .suicidalIdeation)
    }

    func testDetectsKillMyself() {
        let result = sut.detect(query: "I want to kill myself")
        XCTAssertTrue(result.isEmergency)
        XCTAssertEqual(result.symptomType, .suicidalIdeation)
    }

    func testDetectsSuicidalIdeationVietnamese() {
        let result = sut.detect(query: "Tôi muốn chết, không muốn sống nữa")
        XCTAssertTrue(result.isEmergency)
        XCTAssertEqual(result.symptomType, .suicidalIdeation)
    }

    func testSuicidalIdeationRecommendationContainsCrisisHotline() {
        let result = sut.detect(query: "want to die")
        XCTAssertTrue(result.recommendation?.contains("1925") ?? false,
                      "Suicidal ideation response should include Vietnam crisis hotline 1925")
    }

    // MARK: - Stroke Symptoms

    func testDetectsFaceDrooping() {
        let result = sut.detect(query: "face drooping on one side")
        XCTAssertTrue(result.isEmergency)
        XCTAssertEqual(result.symptomType, .strokeSymptom)
    }

    func testDetectsArmWeakness() {
        let result = sut.detect(query: "sudden arm weakness and speech difficulty")
        XCTAssertTrue(result.isEmergency)
        XCTAssertEqual(result.symptomType, .strokeSymptom)
    }

    func testDetectsStrokeVietnamese() {
        let result = sut.detect(query: "Mặt bị xệch và yếu tay trái")
        XCTAssertTrue(result.isEmergency)
        XCTAssertEqual(result.symptomType, .strokeSymptom)
    }

    func testStrokeRecommendationContainsEmergencyNumber() {
        let result = sut.detect(query: "face drooping")
        XCTAssertTrue(result.recommendation?.contains("119") ?? false)
    }

    // MARK: - Severe Bleeding

    func testDetectsHeavyBleeding() {
        let result = sut.detect(query: "There is heavy bleeding from the wound and I can't stop it")
        XCTAssertTrue(result.isEmergency)
        XCTAssertEqual(result.symptomType, .severeBleeding)
    }

    func testDetectsSevereBleedingVietnamese() {
        let result = sut.detect(query: "Vết thương đang chảy máu nhiều không cầm được")
        XCTAssertTrue(result.isEmergency)
        XCTAssertEqual(result.symptomType, .severeBleeding)
    }

    // MARK: - Loss of Consciousness

    func testDetectsLostConsciousness() {
        let result = sut.detect(query: "The patient lost consciousness suddenly")
        XCTAssertTrue(result.isEmergency)
        XCTAssertEqual(result.symptomType, .lossOfConsciousness)
    }

    func testDetectsFainting() {
        let result = sut.detect(query: "fainting and cannot be woken up")
        XCTAssertTrue(result.isEmergency)
        XCTAssertEqual(result.symptomType, .lossOfConsciousness)
    }

    func testDetectsLossOfConsciousnessVietnamese() {
        let result = sut.detect(query: "Bệnh nhân đang bất tỉnh")
        XCTAssertTrue(result.isEmergency)
        XCTAssertEqual(result.symptomType, .lossOfConsciousness)
    }

    // MARK: - All Emergency Results Have Recommendations

    func testAllEmergencyTypesHaveRecommendation() {
        let queries: [(String, EmergencySymptomType)] = [
            ("chest pain", .chestPain),
            ("difficulty breathing", .difficultyBreathing),
            ("seizure", .seizure),
            ("want to die", .suicidalIdeation),
            ("face drooping", .strokeSymptom),
            ("heavy bleeding", .severeBleeding),
            ("lost consciousness", .lossOfConsciousness),
        ]
        for (query, expectedType) in queries {
            let result = sut.detect(query: query)
            XCTAssertTrue(result.isEmergency, "'\(query)' should be detected as emergency")
            XCTAssertEqual(result.symptomType, expectedType, "'\(query)' should map to \(expectedType)")
            XCTAssertNotNil(result.recommendation, "'\(query)' emergency should have a recommendation")
        }
    }
}
