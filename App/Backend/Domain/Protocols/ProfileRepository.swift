import Foundation

protocol ProfileRepository {
    func fetchProfile() async throws -> PatientProfile
    /// Upserts the single profile this repository is scoped to.
    func save(_ profile: PatientProfile) async throws
}
