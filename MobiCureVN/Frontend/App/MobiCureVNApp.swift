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
        // Enable real-model flow at startup.
        AppConfig.useRealLLM = true



        print("MobiCureVNApp: starting model initialization task")

        Task(priority: .utility) {
            await AppConfig.initializeLLMService(
                modelName: "qwen-2.5-7b-instruct",
                progress: { progress in
                    let percent = Int(progress * 100)
                    Task { @MainActor in
                        print("Model download progress: \(percent)%")
                    }
                },
            )
        }
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
        }
    }
}
