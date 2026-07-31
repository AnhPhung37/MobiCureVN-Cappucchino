import Foundation

/// Gate for the first-launch onboarding flow (welcome / disclaimer / language).
/// Absent key already reads `false` via `UserDefaults.bool(forKey:)`, so no default
/// needs registering in `AppConfig.registerDefaults()`.
enum OnboardingState {
    static let storageKey = "hasCompletedOnboarding"
}
