//
//  MobiCureVNApp.swift
//  MobiCureVN
//
//  Created by Anh Phung on 4/24/26.
//

import SwiftUI
import NaturalLanguage

@main
struct MobiCureVNApp: App {

    init() {
        // Must run before initializeLLMService so UserDefaults.bool(forKey:) doesn't
        // silently return false for keys that have never been explicitly written.
        AppConfig.registerDefaults()
        AppConfig.observeMemoryWarnings()

        let isSimulator = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] != nil
        let initializeRuntime = !isSimulator
            && !ProcessInfo.processInfo.isiOSAppOnMac
            && !ProcessInfo.processInfo.isMacCatalystApp

        // Warm up NLEmbedding in the background so the CoreML model is loaded
        // before the user's first message, eliminating the cold-start penalty.
        Task(priority: .background) {
            _ = NLEmbedding.sentenceEmbedding(for: .english)
        }

        // Force the shared SQLite + CoreML query-embedder to initialize off the main thread.
        // Otherwise the first access happens lazily inside ChatViewModel.init (@MainActor),
        // opening the DB and loading the embedder model on the main thread → launch hitch.
        Task(priority: .utility) {
            _ = AppConfig.retriever
        }

        Task(priority: .utility) {
            await AppConfig.initializeLLMService(model: AppConfig.selectedModel,
                                                 initializeRuntime: initializeRuntime)
        }

        Task(priority: .utility) {
            await AppConfig.initializeMedicalAnchors()
        }
    }

    var body: some Scene {
        WindowGroup {
            AppRootView()
        }
    }
}
