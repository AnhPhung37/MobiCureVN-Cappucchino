//
//  LLMServiceProtocol.swift
//  MobiCureVN
//
//  Created by Anh Phung on 4/24/26.
//

import Foundation

protocol LLMServiceProtocol {
    nonisolated func stream(request: LLMRequest) -> AsyncStream<String>
}
