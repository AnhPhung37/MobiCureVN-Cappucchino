//
//  AppConfig.swift
//  MobiCureVN
//
//  Created by Anh Phung on 4/24/26.
//

import Foundation

struct AppConfig {

    /// Inject the correct LLM backend based on build target.
    /// For local testing, always use the mock service.
    /// Re-enable a real backend later by swapping this implementation.
    static var llmService: LLMServiceProtocol {
        return MockLLMService()
    }
}
