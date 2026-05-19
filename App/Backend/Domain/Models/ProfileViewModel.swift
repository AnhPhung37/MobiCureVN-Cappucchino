import Foundation
import Observation

@Observable
final class ProfileViewModel {
    private let repository: ProfileRepository

    init(repository: ProfileRepository) {
        self.repository = repository
    }

    var profile: PatientProfile?
    var isLoading: Bool = false
    var errorMessage: String?

    @MainActor
    func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let result = try await repository.fetchProfile()
            profile = result
        } catch {
            errorMessage = String(describing: error)
        }
        isLoading = false
    }
}
