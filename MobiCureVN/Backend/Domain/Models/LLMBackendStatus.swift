//
//  LLMBackendStatus.swift
//  MobiCureVN
//
//  Created by GitHub Copilot on 5/1/26.
//

import Foundation

enum LLMBackendStatus: String {
    case mock
    case mockWithDownloadedModel
    case loading
    case localModelReady
    case unavailable
}
