import SwiftUI

enum AppearanceMode: String, CaseIterable, Sendable {
    case light
    case dark

    static let storageKey = "AppAppearanceMode"

    var colorScheme: ColorScheme? {
        switch self {
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    var next: AppearanceMode {
        switch self {
        case .light:
            return .dark
        case .dark:
            return .light
        }
    }

    var iconName: String {
        switch self {
        case .light:
            return "moon.stars.fill"
        case .dark:
            return "sun.max.fill"
        }
    }
}