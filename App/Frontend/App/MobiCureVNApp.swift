//
//  MobiCureVNApp.swift
//  MobiCureVN
//
//  Created by Anh Phung on 4/24/26.
//

import SwiftUI

@main
struct MobiCureVNApp: App {

    init() {
        // Must run before initializeLLMService so UserDefaults.bool(forKey:) doesn't
        // silently return false for keys that have never been explicitly written.
        AppConfig.registerDefaults()
        AppConfig.observeMemoryWarnings()

        let initializeRuntime = AppConfig.shouldInitializeRuntime

        // Force the shared SQLite + CoreML query-embedder to initialize off the main thread.
        // Otherwise the first access happens lazily inside ChatViewModel.init (@MainActor),
        // opening the DB and loading the embedder model on the main thread → launch hitch.
        //
        // This only genuinely runs off the main thread because `AppConfig.retriever` and
        // `SQLiteRetriever` are now explicitly non-isolated. Under this target's
        // `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` default they were main-actor isolated,
        // which meant this task hopped straight back to the main thread and did the exact
        // opposite of what the comment above claims. Do not drop those annotations without
        // deleting this warm-up too. See Docs/BE/optimizationChecklist.md B3.2.
        Task(priority: .utility) {
            _ = AppConfig.retriever
        }

        Task(priority: .utility) {
            await AppConfig.initializeLLMService(model: AppConfig.selectedModel,
                                                 initializeRuntime: initializeRuntime)
        }
    }

    var body: some Scene {
        WindowGroup {
            AppRootView()
        }
    }
}
