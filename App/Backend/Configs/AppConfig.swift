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
    static let llmDownloadProgressDidChange = Notification.Name("AppConfigLLMDownloadProgressDidChange")
    static let llmStatusUserInfoKey = "llmStatus"
    static let llmServiceUserInfoKey = "llmService"
    static let llmDownloadProgressUserInfoKey = "llmDownloadProgress"

    /// Stored LLM service instance. Default to mock for fast startup.
    static var llmService: LLMServiceProtocol = MockLLMService() {
        didSet {
            NotificationCenter.default.post(name: llmServiceDidChange,
                                            object: nil,
                                            userInfo: [llmServiceUserInfoKey: llmService])
            // Update orchestrator with new service
            orchestrator = MedicalChatOrchestrator(llmService: llmService)
        }
    }
    
    /// Medical chat orchestrator: full pipeline with guardrails + RAG
    static var orchestrator: MedicalChatOrchestrator = MedicalChatOrchestrator(
        llmService: MockLLMService()
    )

    private(set) static var llmStatus: LLMBackendStatus = .mock {
        didSet {
            NotificationCenter.default.post(name: llmStatusDidChange,
                                            object: nil,
                                            userInfo: [llmStatusUserInfoKey: llmStatus])
        }
    }

    private(set) static var llmDownloadProgress: Double = 0 {
        didSet {
            NotificationCenter.default.post(name: llmDownloadProgressDidChange,
                                            object: nil,
                                            userInfo: [llmDownloadProgressUserInfoKey: llmDownloadProgress])
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

    private static func updateDownloadProgress(_ value: Double) {
        let clamped = min(max(value, 0), 1)
        guard llmDownloadProgress != clamped else { return }
        llmDownloadProgress = clamped
    }

    /// Attempt to use local model if available, otherwise use mock while downloading in background.
    /// Call this from app startup inside a Task.
    static func initializeLLMService(modelName: String = "mlx-community/Qwen2.5-3B-Instruct-4bit",
                                     initializeRuntime: Bool = true) async {
        print("AppConfig: initializeLLMService called")

        guard useRealLLM else {
            updateStatus(.mock)
            print("AppConfig: useRealLLM is false — keeping MockLLMService")
            return
        }

        guard initializeRuntime else {
            updateStatus(.mockWithDownloadedModel)
            print("AppConfig: runtime initialization disabled for this environment")
            return
        }

        updateStatus(.loading)
        updateDownloadProgress(0)

        Task(priority: .utility) {
            do {
                let modelURL = try await ModelManager.shared.ensureModelReady(
                    modelName: modelName,
                    progress: { value in
                        Task { @MainActor in
                            updateDownloadProgress(value)
                        }
                    }
                )
                print("AppConfig: model ready at \(modelURL.path)")

                let service = LLMService(modelPath: modelURL.path, useMock: false)
                llmService = service
                updateStatus(.mockWithDownloadedModel)
                print("AppConfig: model downloaded, MLX integration pending")
            } catch {
                updateStatus(.unavailable)
                print("AppConfig: model setup failed: \(error). Continuing with MockLLMService.")
            }
        }
    }
}
