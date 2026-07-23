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
    /// Posted whenever the set of in-flight background downloads changes — a download starts,
    /// reports progress, finishes, or fails. Carries the full progress map so observers can
    /// render per-model spinners in the picker without tracking each model individually.
    static let modelDownloadsDidChange = Notification.Name("AppConfigModelDownloadsDidChange")
    static let llmStatusUserInfoKey = "llmStatus"
    static let llmServiceUserInfoKey = "llmService"
    static let llmDownloadProgressUserInfoKey = "llmDownloadProgress"
    static let modelDownloadsUserInfoKey = "modelDownloads"

    /// Stored LLM service instance. Defaults to MockLLMService for fast startup;
    /// replaced with the real LLMService once the on-device model is ready.
    static var llmService: LLMServiceProtocol = MockLLMService() {
        didSet {
            NotificationCenter.default.post(name: llmServiceDidChange,
                                            object: nil,
                                            userInfo: [llmServiceUserInfoKey: llmService])
        }
    }

    /// Single SwiftData container shared by every repository.
    ///
    /// All `@Model` types MUST be registered here. SwiftData derives the SQLite schema from
    /// the model set the container is opened with, so two containers opened against the same
    /// on-disk store (`Library/Application Support/default.store`) with *different* model sets
    /// each create only their own tables — whichever opens first wins, and the other reports
    /// `no such table: ZCHATRECORD` / `ZWOUNDLOGRECORD` I/O errors. One container over the full
    /// schema keeps the store consistent.
    static let modelContainer: ModelContainer? = {
        do {
            return try ModelContainer(for: ChatRecord.self, WoundLogRecord.self)
        } catch {
            assertionFailure("Failed to create shared SwiftData container: \(error)")
            return nil
        }
    }()

    static let chatHistoryRepository: ChatHistoryRepository = {
        do {
            guard let modelContainer else { return InMemoryChatHistoryRepository() }
            return try SwiftDataChatHistoryRepository(container: modelContainer)
        } catch {
            assertionFailure("Failed to create SwiftData chat history repository: \(error)")
            return InMemoryChatHistoryRepository()
        }
    }()

    static let woundLogRepository: WoundLogRepository = {
        do {
            guard let modelContainer else { return InMemoryWoundLogRepository() }
            return try SwiftDataWoundLogRepository(container: modelContainer)
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

    // MARK: - Background Model Downloads
    //
    // Downloads are decoupled from the single active-model state (`llmStatus` /
    // `llmService`). Any number of models can download in parallel while a *different*,
    // already-downloaded model stays active and usable for chat. The registry below is the
    // source of truth for "what is downloading"; the active model is still tracked by
    // `llmStatus`/`llmService`.
    //
    // These are @MainActor because they mutate shared UI-observed state and post
    // notifications; the download work itself runs off-actor inside the task.

    /// In-flight download tasks, keyed by model. Cancelling the task cancels the download.
    @MainActor private static var downloadTasks: [ModelCatalog: Task<Void, Never>] = [:]

    /// Latest reported progress (0...1) for each in-flight download.
    @MainActor private(set) static var modelDownloadProgress: [ModelCatalog: Double] = [:] {
        didSet {
            NotificationCenter.default.post(name: modelDownloadsDidChange,
                                            object: nil,
                                            userInfo: [modelDownloadsUserInfoKey: modelDownloadProgress])
        }
    }

    /// Whether a background download is currently in flight for `model`.
    @MainActor static func isDownloading(_ model: ModelCatalog) -> Bool {
        downloadTasks[model] != nil
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

    /// Switches which on-device model chat uses. Persists the selection, then:
    ///
    /// - If the target is **already on disk**, it is loaded and made active immediately — the
    ///   old MLX model is released first so two multi-GB models are never resident at once.
    ///   This is the fast path that works even while *other* models are downloading in the
    ///   background: a background download is only file I/O and never holds a model in MLX.
    /// - If the target is **not on disk**, the currently active model stays active and usable,
    ///   and the target starts downloading in the background. When that download finishes it
    ///   becomes active only if the user is still pointing at it (they may have switched again).
    ///
    /// No-op when the requested model is already the active, healthy model.
    @MainActor
    static func switchModel(to model: ModelCatalog) async {
        guard model != selectedModel || llmStatus == .unavailable else { return }
        selectedModel = model

        guard useRealLLM, shouldInitializeRuntime else {
            // Simulator/Mac or mock mode: nothing to load; startup already set the status.
            await initializeLLMService(model: model, initializeRuntime: shouldInitializeRuntime)
            return
        }

        if ModelManager.shared.isModelDownloaded(repoID: model.repoID) {
            // On disk already — a background download of this same model (if any) is now moot.
            cancelDownload(model)
            await activateDownloadedModel(model)
        } else {
            // Keep the current active model running; fetch the new one in the background.
            startBackgroundDownload(model)
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

    /// Loads an on-disk model into MLX and makes it the active chat service. Releases the
    /// previously active MLX model first so only one model is ever resident. Chat falls back
    /// to the mock service during the (fast) load of weights already cached on disk.
    @MainActor
    private static func activateDownloadedModel(_ model: ModelCatalog) async {
        guard let modelURL = try? ModelManager.shared.localModelURL(repoID: model.repoID) else {
            updateStatus(.unavailable)
            return
        }

        if let realService = llmService as? LLMService {
            realService.unload()
        }
        llmService = MockLLMService()

        updateStatus(.loading)
        updateDownloadProgress(1)

        let service = LLMService(modelPath: modelURL.path, useMock: false)
        llmService = service
        updateStatus(.mockWithDownloadedModel)

        let initialized = await service.initializeModel()
        if initialized {
            updateStatus(.localModelReady)
            print("AppConfig: MLX runtime ready for \(model.displayName)")
        } else {
            print("AppConfig: MLX runtime unavailable for \(model.displayName), using placeholder responses")
        }
    }

    /// Starts (or reuses) a background download for `model`. Multiple models may download in
    /// parallel; each is tracked independently in `downloadTasks` / `modelDownloadProgress`.
    /// On success the model becomes active only if it is still the user's current selection.
    @MainActor
    private static func startBackgroundDownload(_ model: ModelCatalog) {
        guard downloadTasks[model] == nil else { return }  // already downloading

        modelDownloadProgress[model] = 0
        // Mirror into the legacy single-value progress/status when this download is for the
        // model the user is currently waiting on, so the existing status chip keeps working.
        if model == selectedModel {
            updateStatus(.loading)
            updateDownloadProgress(0)
        }

        let task = Task<Void, Never>(priority: .utility) {
            do {
                _ = try await ModelManager.shared.ensureModelReady(
                    modelName: model.repoID,
                    progress: { value in
                        Task { @MainActor in
                            modelDownloadProgress[model] = min(max(value, 0), 1)
                            if model == selectedModel { updateDownloadProgress(value) }
                        }
                    }
                )
                await MainActor.run { finishDownload(model, succeeded: true) }
            } catch is CancellationError {
                await MainActor.run { finishDownload(model, succeeded: false) }
            } catch {
                print("AppConfig: background download failed for \(model.displayName): \(error)")
                await MainActor.run {
                    if model == selectedModel { updateStatus(.unavailable) }
                    finishDownload(model, succeeded: false)
                }
            }
        }
        downloadTasks[model] = task
    }

    /// Clears a download's registry entry and, on success, activates the model if the user is
    /// still pointing at it (they may have switched to a third model while this downloaded).
    @MainActor
    private static func finishDownload(_ model: ModelCatalog, succeeded: Bool) {
        downloadTasks[model] = nil
        modelDownloadProgress[model] = nil

        guard succeeded else { return }
        if model == selectedModel {
            Task { await activateDownloadedModel(model) }
        }
    }

    /// Cancels the in-flight background download for `model`, if any.
    @MainActor
    static func cancelDownload(_ model: ModelCatalog) {
        downloadTasks[model]?.cancel()
        // finishDownload (via the task's CancellationError path) clears the registry entries.
    }

    /// Attempt to use local model if available, otherwise use mock while downloading in background.
    /// Call this from app startup inside a Task.
    @MainActor
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

        if ModelManager.shared.isModelDownloaded(repoID: model.repoID) {
            await activateDownloadedModel(model)
        } else {
            startBackgroundDownload(model)
        }
    }
}
