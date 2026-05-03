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

    /// Attempt to use local model if available, otherwise use mock while downloading in background.
    /// Call this from app startup (e.g., `@main` or AppDelegate`) inside a Task.
    static func initializeLLMService(modelName: String = "qwen-2.5-7b-instruct",
                                     archiveURL: URL? = nil,
                                     checksum: String? = nil,
                                     progress: ((Double) -> Void)? = nil,
                                     authToken: String? = nil,
                                     repoID: String? = nil,
                                     initializeRuntime: Bool = true) async {
        print("AppConfig: initializeLLMService called")
        progress?(0.0)

        guard useRealLLM else {
            updateStatus(.mock)
            print("AppConfig: useRealLLM is false — keeping MockLLMService")
            return
        }

        // Check if model exists locally. If it does, keep that path attached to chat and do not redownload.
        if let localModelPath = ModelManager.shared.getLocalModelPath(modelName: modelName, repoID: repoID) {
            print("AppConfig: found local model at \(localModelPath.path)")

            let service = LLMService(modelPath: localModelPath.path, useMock: false)
            llmService = service

            if initializeRuntime, await service.initializeModel() {
                updateStatus(.localModelReady)
                print("AppConfig: switched to real LLMService at \(localModelPath.path)")
                progress?(1.0)
            } else {
                updateStatus(.mockWithDownloadedModel)
                print("AppConfig: local model is attached, but MLX is not ready for \(localModelPath.path)")
            }
            return
        }

        // Model not found locally, use mock and download in background.
        updateStatus(.mock)
        print("AppConfig: local model not found, using MockLLMService and starting download")

        // Download model in background
        Task(priority: .utility) {
            do {
                let modelURL = try await ModelManager.shared.ensureModelReady(
                    modelName: modelName,
                    archiveURL: archiveURL,
                    expectedSHA256: checksum,
                    progress: progress,
                    authToken: authToken,
                    repoID: repoID
                )
                
                print("AppConfig: model download completed at \(modelURL.path)")

                if initializeRuntime {
                    // Now try to initialize the real service
                    let service = LLMService(modelPath: modelURL.path, useMock: false)
                    if await service.initializeModel() {
                        llmService = service
                        updateStatus(.localModelReady)
                        print("AppConfig: switched to real LLMService after download")
                    } else {
                        updateStatus(.mockWithDownloadedModel)
                        print("AppConfig: model downloaded but MLX could not initialize it")
                    }
                } else {
                    updateStatus(.mockWithDownloadedModel)
                    print("AppConfig: model downloaded, keeping MockLLMService for this run")
                }
            } catch {
                updateStatus(.unavailable)
                print("AppConfig: model download failed: \(error). Continuing with MockLLMService.")
            }
        }
    }
}
