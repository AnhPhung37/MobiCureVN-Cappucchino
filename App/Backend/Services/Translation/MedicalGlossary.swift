import Foundation

/// Pins colorectal-recovery vocabulary to its clinical English meaning **before** Apple
/// Translation sees the text.
///
/// Apple Translation is a general-purpose model with no idea the user is a post-surgery patient.
/// Patient phrasings for stoma and drain equipment are everyday words in isolation, so it picks
/// the everyday reading: "Túi dịch của tôi đang bị tràn" came back as "My water bottle is
/// overflowing", and the orchestrator then gave advice about a water bottle.
///
/// Strategy: swap each known Vietnamese phrase for its English term inline, producing
/// code-switched text ("ostomy pouch của tôi đang bị tràn"). The vi→en session passes English
/// tokens through untouched, so the translated query keeps the clinical term, and RAG plus the
/// scope guardrail (which already know "ostomy", "stoma", "drain") see the right words.
///
/// Only multi-syllable phrases whose everyday translation is wrong or ambiguous in this domain
/// belong here. Matching is whole-phrase (no letter on either side), case-insensitive, longest
/// phrase first so "túi hậu môn nhân tạo" wins over "hậu môn nhân tạo".
struct MedicalGlossary {

    static let entries: [String: String] = [
        // Stoma / ostomy
        "túi hậu môn nhân tạo": "ostomy pouch",
        "hậu môn nhân tạo": "stoma",
        "lỗ hậu môn nhân tạo": "stoma",
        "túi hậu môn": "ostomy pouch",
        "túi phân": "ostomy pouch",
        "túi stoma": "ostomy pouch",
        "túi ostomy": "ostomy pouch",
        "túi dịch": "ostomy pouch",
        "đế túi": "pouch skin barrier",
        "đế dán": "pouch skin barrier",

        // Surgical drains
        "túi dẫn lưu": "drain collection bag",
        "ống dẫn lưu": "surgical drain",
        "dịch dẫn lưu": "drain fluid",

        // Wound
        "vết mổ": "surgical incision",
        "chỉ khâu": "stitches",
        "bục chỉ": "stitches coming apart",

        // Bowel
        "miệng nối": "anastomosis",
        "rò miệng nối": "anastomotic leak",
        "tắc ruột": "bowel obstruction",
        "xì hơi": "passing gas",
        "trung tiện": "passing gas",
        "đại trực tràng": "colorectal",

        // Catheters
        "ống thông tiểu": "urinary catheter",
        "sonde tiểu": "urinary catheter",
    ]

    // Longest phrase first, compiled once. Lookarounds on \p{L} give a Unicode-aware word
    // boundary (\b treats Vietnamese diacritics inconsistently).
    private static let patterns: [(regex: NSRegularExpression, english: String)] =
        entries
            .sorted { $0.key.count > $1.key.count }
            .compactMap { vi, en in
                let escaped = NSRegularExpression.escapedPattern(
                    for: vi.precomposedStringWithCanonicalMapping
                )
                guard let regex = try? NSRegularExpression(
                    pattern: "(?<!\\p{L})\(escaped)(?!\\p{L})",
                    options: [.caseInsensitive]
                ) else { return nil }
                return (regex, en)
            }

    /// Returns `text` with every glossary phrase replaced by its English term. Input is
    /// NFC-normalised first so decomposed diacritics (common from some keyboards) still match.
    func apply(_ text: String) -> String {
        var result = text.precomposedStringWithCanonicalMapping
        for (regex, english) in Self.patterns {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(
                in: result, range: range,
                withTemplate: NSRegularExpression.escapedTemplate(for: english)
            )
        }
        return result
    }
}
