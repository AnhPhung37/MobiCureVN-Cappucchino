import Foundation

/// User-configurable text-size preference (Profile > Text Size). Independent of iOS's own
/// Dynamic Type accessibility setting — the app's font sizes are arbitrary pixel values, not
/// semantic text styles, so a flat scale factor is applied instead via `View.appFont(...)`.
enum TextSizeOption: String, CaseIterable {
    case standard
    case large
    case extraLarge

    static let storageKey = "AppTextSizeOption"

    var scaleFactor: CGFloat {
        switch self {
        case .standard: return 1.0
        case .large: return 1.15
        case .extraLarge: return 1.3
        }
    }

    /// Vietnamese source string, matching the rest of the app's Localizable.xcstrings convention.
    var displayName: String {
        switch self {
        case .standard: return "Chuẩn"
        case .large: return "Lớn"
        case .extraLarge: return "Rất lớn"
        }
    }
}
