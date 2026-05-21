//
//  AppConfig.swift
//  MobiCureVN
//
//  Created by Anh Phung on 4/24/26.
//

import Foundation
import SwiftData

struct AppConfig {

    // Shared on-device translation service. @MainActor because TranslationSession is @MainActor.
    // Populated by the .translationTask() modifiers in ChatView.
    @MainActor
    static let translationService = TranslationService()

    static let llmStatusDidChange = Notification.Name("AppConfigLLMStatusDidChange")
    static let llmServiceDidChange = Notification.Name("AppConfigLLMServiceDidChange")
    static let llmDownloadProgressDidChange = Notification.Name("AppConfigLLMDownloadProgressDidChange")
    static let llmStatusUserInfoKey = "llmStatus"
    static let llmServiceUserInfoKey = "llmService"
    static let llmDownloadProgressUserInfoKey = "llmDownloadProgress"

    /// Stored LLM service instance. Starts with a placeholder LLMService; replaced once the model is ready.
    static var llmService: LLMServiceProtocol = LLMService() {
        didSet {
            NotificationCenter.default.post(name: llmServiceDidChange,
                                            object: nil,
                                            userInfo: [llmServiceUserInfoKey: llmService])
            orchestrator = MedicalChatOrchestrator(llmService: llmService)
        }
    }

    /// Medical chat orchestrator: full pipeline with guardrails + RAG
    static var orchestrator: MedicalChatOrchestrator = MedicalChatOrchestrator(
        llmService: LLMService()
    )

    static let chatHistoryRepository: ChatHistoryRepository = {
        do {
            return try SwiftDataChatHistoryRepository()
        } catch {
            assertionFailure("Failed to create SwiftData chat history repository: \(error)")
            return InMemoryChatHistoryRepository()
        }
    }()

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
    // MARK: - Kaggle Dataset Config
    // Credentials live in Secrets.swift (gitignored). See Secrets.swift.example for the template.
    static let kaggleUsername = Secrets.kaggleUsername
    static let kaggleApiKey   = Secrets.kaggleApiKey

    /// Downloads the Kaggle medical-text dataset (if not already cached in the temp directory)
    /// and updates GuardRailRules.medicalAnchors. Safe to call at startup from a background task.
    static func initializeMedicalAnchors() async {
        let anchors = await MedicalAnchorLoader.shared.load(
            username: kaggleUsername,
            apiKey: kaggleApiKey
        )
        GuardRailRules.updateMedicalAnchors(anchors)
    }

    private static let useRealKey = "UseRealLLM"
    private static let selectedModelKey = "SelectedLLMModel"

    static var useRealLLM: Bool {
        get { UserDefaults.standard.bool(forKey: useRealKey) }
        set { UserDefaults.standard.set(newValue, forKey: useRealKey) }
    }

    static var selectedModel: ModelCatalog {
        get {
            guard let raw = UserDefaults.standard.string(forKey: selectedModelKey),
                  let model = ModelCatalog(rawValue: raw) else { return .default }
            return model
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: selectedModelKey) }
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
    static func initializeLLMService(model: ModelCatalog = .default,
                                     initializeRuntime: Bool = true) async {
        print("AppConfig: initializeLLMService called with \(model.displayName)")

        guard useRealLLM else {
            updateStatus(.mock)
            print("AppConfig: useRealLLM is false — keeping MockLLMService")
            return
        }

        guard initializeRuntime else {
            print("AppConfig: simulator/Mac — skipping model download, placeholder responses active")
            updateStatus(.unavailable)
            return
        }

        updateStatus(.loading)
        updateDownloadProgress(0)

        Task(priority: .utility) {
            do {
                let modelURL = try await ModelManager.shared.ensureModelReady(
                    modelName: model.repoID,
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

                let initialized = await service.initializeModel()
                if initialized {
                    updateStatus(.localModelReady)
                    print("AppConfig: MLX runtime ready")
                } else {
                    print("AppConfig: MLX runtime unavailable, using placeholder responses")
                }
            )
            print("AppConfig: model ready at \(modelURL.path)")

            let service = LLMService(modelPath: modelURL.path, useMock: false)
            llmService = service
            updateStatus(.mockWithDownloadedModel)

            let initialized = await service.initializeModel()
            if initialized {
                updateStatus(.localModelReady)
                print("AppConfig: MLX runtime ready")
            } else {
                print("AppConfig: MLX runtime unavailable — model downloaded but running in placeholder mode")
            }
        } catch {
            updateStatus(.unavailable)
            print("AppConfig: model setup failed: \(error)")
        }
    }
}
