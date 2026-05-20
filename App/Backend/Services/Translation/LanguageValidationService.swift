import NaturalLanguage

// Result of language detection for a user-submitted string.
enum DetectedLanguage: Equatable {
    case vietnamese
    case english
    case mixed              // Vietnamese-English code-switching — treated as Vietnamese
    case unsupported(detected: String)

    static func == (lhs: DetectedLanguage, rhs: DetectedLanguage) -> Bool {
        switch (lhs, rhs) {
        case (.vietnamese, .vietnamese), (.english, .english), (.mixed, .mixed):
            return true
        case (.unsupported(let a), .unsupported(let b)):
            return a == b
        default:
            return false
        }
    }

    // Whether the pipeline must route through translation (vi → en → vi).
    var requiresTranslation: Bool {
        self == .vietnamese || self == .mixed
    }
}

final class LanguageValidationService {

    static let unsupportedErrorMessage =
        "Xin lỗi, hệ thống chỉ hỗ trợ tiếng Việt và tiếng Anh. / " +
        "Sorry, this system only supports Vietnamese and English."

    // MARK: - Public API

    func detect(_ text: String) -> DetectedLanguage {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .english }

        let hasVietnamese = containsVietnameseDiacritics(trimmed)

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)

        let hypotheses = recognizer.languageHypotheses(withMaximum: 5)
        let viScore = hypotheses[.vietnamese] ?? 0
        let enScore = hypotheses[.english] ?? 0

        guard let dominant = recognizer.dominantLanguage else {
            // No dominant language detected — fall back to diacritic presence
            return hasVietnamese ? .vietnamese : .unsupported(detected: "unknown")
        }

        switch dominant {
        case .vietnamese:
            return .vietnamese

        case .english:
            // English-dominant text that also contains Vietnamese diacritics → mixed
            if hasVietnamese || viScore > 0.15 {
                return .mixed
            }
            return .english

        default:
            // Neither vi nor en is dominant, but the text has Vietnamese characters
            if hasVietnamese {
                return viScore >= enScore ? .vietnamese : .mixed
            }
            // High English confidence despite wrong dominant (some Latin-script languages
            // get misclassified; accept them rather than rejecting English speakers)
            if enScore > 0.6 {
                return .english
            }
            return .unsupported(detected: dominant.rawValue)
        }
    }

    // MARK: - Private

    // Matches characters that appear only in Vietnamese (tone marks + ă, đ, ơ, ư and their
    // combining forms) so we can detect Vietnamese presence even when NL mis-classifies.
    private func containsVietnameseDiacritics(_ text: String) -> Bool {
        let pattern = "[àáâãèéêìíòóôõùúý" +
                      "ăđơư" +
                      "ạảấầẩẫậắằẳẵặẹẻẽếềểễệỉịọỏốồổỗộớờởỡợụủứừửữựỳỵỷỹ" +
                      "ÀÁÂÃÈÉÊÌÍÒÓÔÕÙÚÝ" +
                      "ĂĐƠƯ]"
        return text.range(of: pattern, options: .regularExpression) != nil
    }
}
