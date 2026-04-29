//
//  LLMServiceProtocol.swift
//  MobiCureVN
//
//  Created by Anh Phung on 4/24/26.
//

import Foundation

protocol LLMServiceProtocol {
    func stream(request: LLMRequest) -> AsyncStream<String>
}
