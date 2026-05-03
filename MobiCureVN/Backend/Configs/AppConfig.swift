//
//  AppConfig.swift
//  MobiCureVN
//
//  Created by Anh Phung on 4/24/26.
//

import Foundation

struct AppConfig {

    static let llmStatusDidChange = Notification.Name("AppConfigLLMStatusDidChange")
    static let llmServiceDidChange = Notification.Name("AppConfigLLMServiceDidChange")
    static let llmStatusUserInfoKey = "llmStatus"
    static let llmServiceUserInfoKey = "llmService"

    /// Stored LLM service instance. Default to mock for fast startup.
    static var llmService: LLMServiceProtocol = MockLLMService() {
        didSet {
            NotificationCenter.default.post(name: llmServiceDidChange,
                                            object: nil,
                                            userInfo: [llmServiceUserInfoKey: llmService])
        }
    }

    private(set) static var llmStatus: LLMBackendStatus = .mock {
        didSet {
            NotificationCenter.default.post(name: llmStatusDidChange,
                                            object: nil,
                                            userInfo: [llmStatusUserInfoKey: llmStatus])
        }
    }
    /// Key for runtime toggle in `UserDefaults`.
    private static let useRealKey = "UseRealLLM"

    static var useRealLLM: Bool {
        get { UserDefaults.standard.bool(forKey: useRealKey) }
        set { UserDefaults.standard.set(newValue, forKey: useRealKey) }
    }

    private static func updateStatus(_ status: LLMBackendStatus) {
        guard llmStatus != status else { return }
        llmStatus = status
    }

    /// Attempt to ensure a model is available and switch to a real `LLMService`.
    /// Call this from app startup (e.g., `@main` or AppDelegate`) inside a Task.
    static func initializeLLMService(modelName: String = "qwen-2.5-7b-instruct",
                                     archiveURL: URL? = nil,
                                     checksum: String? = nil,
                                     progress: ((Double) -> Void)? = nil,
                                     authToken: String? = nil,
                                     repoID: String? = nil) async {
        print("AppConfig: initializeLLMService called")
        progress?(0.0)

        guard useRealLLM else {
            updateStatus(.mock)
            print("AppConfig: useRealLLM is false — keeping MockLLMService")
            return
        }

        updateStatus(.loading)

        do {
            let modelURL = try await ModelManager.shared.ensureModelReady(modelName: modelName,
                                                                          archiveURL: archiveURL,
                                                                          expectedSHA256: checksum,
                                                                          progress: progress,
                                                                          authToken: authToken,
                                                                          repoID: repoID)
            // Replace the service with a real LLMService initialized with the local model path
            let service = LLMService(modelPath: modelURL.path, useMock: false)
            llmService = service
            updateStatus(.localModelReady)
            print("AppConfig: switched to real LLMService at \(modelURL.path)")
            // attempt MLX runtime init (non-blocking)
            Task.detached {
                await service.initializeModel()
            }
        } catch {
            updateStatus(.unavailable)
            // Keep mock service and surface a log — callers can retry later.
            print("Model initialization failed: \(error). Continuing with MockLLMService.")
        }
    }
}
