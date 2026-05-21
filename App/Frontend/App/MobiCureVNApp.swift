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
        let isSimulator = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] != nil
        let initializeRuntime = !isSimulator
            && !ProcessInfo.processInfo.isiOSAppOnMac
            && !ProcessInfo.processInfo.isMacCatalystApp

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
            HomeView()
        }
    }
}
