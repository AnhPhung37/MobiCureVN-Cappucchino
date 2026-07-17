import Foundation

/// UI language selected with the VI/EN toggle in the chat top bar.
/// Persisted in UserDefaults so the choice survives relaunches; defaults to Vietnamese.
enum AppLanguage: String, CaseIterable {
    case vietnamese = "vi"
    case english = "en"

    static let storageKey = "appLanguage"

    var locale: Locale { Locale(identifier: rawValue) }

    static var current: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .vietnamese
    }
}

extension String {
    /// Resolves a Localizable.xcstrings key for a specific language, independent of the
    /// device language. Needed for strings created outside SwiftUI `Text` (view models,
    /// prompts handed to the LLM), which don't follow the `\.locale` environment.
    func localized(for language: AppLanguage) -> String {
        guard let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return self }
        return bundle.localizedString(forKey: self, value: self, table: nil)
    }
}
