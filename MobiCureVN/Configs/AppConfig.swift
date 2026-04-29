//
//  AppConfig.swift
//  MobiCureVN
//
//  Created by Anh Phung on 4/24/26.
//

import Foundation
#if canImport(ChatEngineCore)
import ChatEngineCore
#endif

struct AppConfig {

    /// Inject the correct LLM backend based on build target.
    /// To use mock: add PROTOTYPE to Swift Active Compilation Conditions in Xcode
    /// Build Settings → Swift Compiler - Custom Flags → Active Compilation Conditions
    static var llmService: LLMServiceProtocol {
        #if PROTOTYPE
        return MockLLMService()
        #else
        // Use the in-app backend via the adapter. Configure modelPath/useMock as needed.
        #if canImport(ChatEngineCore)
        let backend = ChatEngineCore.LLMService(modelPath: "mlx-community/Qwen2.5-7B-Instruct-4bit", useMock: false)
        #else
        let backend = LLMService(modelPath: "mlx-community/Qwen2.5-7B-Instruct-4bit", useMock: false)
        #endif
        return InAppBackendLLMServiceAdapter(backend: backend)
        #endif
    }
}
