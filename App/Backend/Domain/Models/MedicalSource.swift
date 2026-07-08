//
//  MedicalSource.swift
//  MobiCureVN
//
//  Created by Anh Phung on 4/24/26.
//

import Foundation

public struct MedicalSource: Identifiable, Sendable, Codable {
    public let id: String
    public let title: String
    public let excerpt: String
    public let page: Int
    public let documentName: String

    public init(id: String, title: String, excerpt: String, page: Int, documentName: String) {
        self.id = id
        self.title = title
        self.excerpt = excerpt
        self.page = page
        self.documentName = documentName
    }
}
