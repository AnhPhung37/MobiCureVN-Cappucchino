import Foundation

protocol ProfileRepository {
    func fetchProfile() async throws -> PatientProfile
}
