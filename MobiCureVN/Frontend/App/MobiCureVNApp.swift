//
//  MobiCureVNApp.swift
//  MobiCureVN
//
//  Created by Anh Phung on 4/24/26.
//

import SwiftUI

@main
struct MobiCureVNApp: App {

    private static let modelRepoIDKey = "ModelRepoID"

    init() {
        AppConfig.useRealLLM = true

        let defaults = UserDefaults.standard
        let repoID = defaults.string(forKey: Self.modelRepoIDKey) ?? "mlx-community/Qwen2.5-3B-Instruct-4bit"
        let initializeRuntime = !ProcessInfo.processInfo.isiOSAppOnMac && !ProcessInfo.processInfo.isMacCatalystApp

        print("MobiCureVNApp: starting model initialization task")

        Task(priority: .utility) {
            await AppConfig.initializeLLMService(
                modelName: repoID,
                progress: { progress in
                    let percent = Int(progress * 100)
                    print("Model download progress: \(percent)%")
                },
                initializeRuntime: initializeRuntime
            )
        }
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
        }
    }
}
