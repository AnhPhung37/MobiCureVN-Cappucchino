import Foundation

struct MockProfileRepository: ProfileRepository {
    func fetchProfile() async throws -> PatientProfile {
        PatientProfile(
            name: "Nguyen Van A",
            age: 52,
            gender: "Male",
            diagnosis: "Post-operative colorectal cancer recovery",
            procedure: "Bowel surgery",
            recoveryStage: "Early recovery",
            reportSummary: "The patient is in a stable recovery phase after surgery. The current report suggests close monitoring of pain, wound care, diet, and bowel movement changes.",
            careNotes: [
                "Keep the wound clean and dry.",
                "Eat soft and easy-to-digest food.",
                "Drink enough water through the day.",
                "Follow the care plan from the medical team."
            ],
            warningSigns: [
                "Fever or chills",
                "Redness, swelling, or pus at the wound",
                "Sudden pain that gets worse",
                "Trouble eating or drinking"
            ],
            sourceName: "Mock medical report"
        )
    }
}
