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
        AppConfig.useRealLLM = true

        let isSimulator = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] != nil
        let initializeRuntime = !isSimulator
            && !ProcessInfo.processInfo.isiOSAppOnMac
            && !ProcessInfo.processInfo.isMacCatalystApp

        Task(priority: .utility) {
            await AppConfig.initializeLLMService(initializeRuntime: initializeRuntime)
        }
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
        }
    }
}
