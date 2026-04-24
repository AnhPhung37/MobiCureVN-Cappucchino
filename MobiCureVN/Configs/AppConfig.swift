//
//  AppConfig.swift
//  MobiCureVN
//
//  Created by Anh Phung on 4/24/26.
//

import Foundation

struct AppConfig {

    /// Inject the correct LLM backend based on build target.
    /// To use mock: add PROTOTYPE to Swift Active Compilation Conditions in Xcode
    /// Build Settings → Swift Compiler - Custom Flags → Active Compilation Conditions
    static var llmService: LLMServiceProtocol {
        #if PROTOTYPE
        return MockLLMService()
        #elseif DEBUG
        // Swap to MacStudioMLXService() when Hanh's backend is ready
        return MockLLMService()
        #else
        // Production: on-device MLX on iPad Neural Engine
        // return OnDeviceMLXService()
        return MockLLMService() // placeholder until prod service is built
        #endif
    }
}
