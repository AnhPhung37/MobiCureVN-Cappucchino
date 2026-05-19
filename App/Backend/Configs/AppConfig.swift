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
        print("AppConfig: initializeLLMService called, initializeRuntime=\(initializeRuntime)")

        guard initializeRuntime else {
            print("AppConfig: simulator/Mac — skipping model download, placeholder responses active")
            updateStatus(.unavailable)
            return
        }

        updateStatus(.loading)
        updateDownloadProgress(0)

        do {
            let modelURL = try await ModelManager.shared.ensureModelReady(
                modelName: modelName,
                progress: { value in
                    Task { @MainActor in updateDownloadProgress(value) }
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
