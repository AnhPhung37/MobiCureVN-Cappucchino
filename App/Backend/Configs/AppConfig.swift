//
//  AppConfig.swift
//  MobiCureVN
//
//  Created by Anh Phung on 4/24/26.
//

import Foundation
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

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

    /// Stored LLM service instance. Defaults to MockLLMService for fast startup;
    /// replaced with the real LLMService once the on-device model is ready.
    static var llmService: LLMServiceProtocol = MockLLMService() {
        didSet {
            NotificationCenter.default.post(name: llmServiceDidChange,
                                            object: nil,
                                            userInfo: [llmServiceUserInfoKey: llmService])
        }
    }

    static let chatHistoryRepository: ChatHistoryRepository = {
        do {
            return try SwiftDataChatHistoryRepository()
        } catch {
            assertionFailure("Failed to create SwiftData chat history repository: \(error)")
            return InMemoryChatHistoryRepository()
        }
    }()

    static let woundLogRepository: WoundLogRepository = {
        do {
            return try SwiftDataWoundLogRepository()
        } catch {
            assertionFailure("Failed to create SwiftData wound log repository: \(error)")
            return InMemoryWoundLogRepository()
        }
    }()

    /// Shared SQLiteRetriever — opening a SQLite connection is expensive; reuse one instance
    /// across the RAGService (inside MedicalChatOrchestrator) and ChatViewModel citation lookup.
    static let retriever = SQLiteRetriever()

    /// Shared session-fact store. A `MedicalChatOrchestrator` is recreated on every model swap
    /// (see `ChatViewModel.bindLLMStatusUpdates`); if each carried its own fact store, remembered
    /// facts would be lost on a mid-conversation model switch. Sharing one instance keeps a
    /// conversation's facts stable across swaps and — because facts are keyed by conversationId —
    /// lets the Profile screen read the very facts being injected into the live system prompt.
    static let sessionFactStore = SessionFactStore()

    /// Stable, device-local patient identity used to scope wound-log entries.
    ///
    /// This is a single-user app today — there is no real per-patient profile identity yet
    /// (`PatientProfile.id` is regenerated on every fetch). Rather than block the wound log on
    /// that, we persist one UUID in `UserDefaults` on first access and reuse it for the life of
    /// the install, so a patient's photo history stays coherent across launches. When real
    /// profiles land, migrate existing entries from this id to the profile id.
    private static let localPatientIDKey = "AppConfigLocalPatientID"
    static var localPatientID: UUID = {
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: localPatientIDKey), let id = UUID(uuidString: stored) {
            return id
        }
        let id = UUID()
        defaults.set(id.uuidString, forKey: localPatientIDKey)
        return id
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
    /// Exposed (not private) so the model-picker UI can observe it via @AppStorage.
    static let selectedModelStorageKey = "SelectedLLMModel"

    /// Register defaults once at app start so `bool(forKey:)` never silently returns false.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            useRealKey: true,
            AppearanceMode.storageKey: AppearanceMode.light.rawValue
        ])
    }

    private static var memoryWarningObserver: NSObjectProtocol?

    /// Releases the MLX model and its Metal buffer cache under memory pressure. The next
    /// chat turn falls back to placeholder text until the model reloads; this trades a
    /// worse response for avoiding a jetsam kill. Call once at app start.
    static func observeMemoryWarnings() {
#if canImport(UIKit)
        guard memoryWarningObserver == nil else { return }
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            print("AppConfig: memory warning received — unloading LLM model")
            if let realService = llmService as? LLMService {
                realService.unload()
            }
        }
#endif
    }

    static var useRealLLM: Bool {
        get { UserDefaults.standard.bool(forKey: useRealKey) }
        set { UserDefaults.standard.set(newValue, forKey: useRealKey) }
    }

    static var selectedModel: ModelCatalog {
        get {
            guard let raw = UserDefaults.standard.string(forKey: selectedModelStorageKey),
                  let model = ModelCatalog(rawValue: raw) else { return .default }
            return model
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: selectedModelStorageKey) }
    }

    /// True on physical iOS devices, where the MLX runtime can actually load models.
    /// Simulator and Mac (Catalyst / iOS-on-Mac) builds skip download and use placeholders.
    static var shouldInitializeRuntime: Bool {
        ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] == nil
            && !ProcessInfo.processInfo.isiOSAppOnMac
            && !ProcessInfo.processInfo.isMacCatalystApp
    }

    /// Switches the active on-device model: persists the selection, releases the current
    /// MLX model (a second multi-GB model must never be resident alongside the first),
    /// and downloads/loads the new one. Chat falls back to the mock service until the
    /// new model is ready. No-op when the requested model is already selected and healthy.
    static func switchModel(to model: ModelCatalog) async {
        guard model != selectedModel || llmStatus == .unavailable else { return }
        selectedModel = model

        if let realService = llmService as? LLMService {
            realService.unload()
        }
        llmService = MockLLMService()

        await initializeLLMService(model: model, initializeRuntime: shouldInitializeRuntime)
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
            } catch {
                updateStatus(.unavailable)
                print("AppConfig: model setup failed: \(error)")
            }
        }
    }
}
