import Foundation

/// Parses the VLM's structured wound findings text into the fields of a `WoundLogEntry`.
///
/// The VLM is prompted (see `WoundAnalysisService.findingsSystemPrompt`) to emit one
/// `KEY: value` line per observation using a fixed set of keys. This parser is deliberately
/// deterministic — no second model call — so a given findings string always maps to the same
/// structured fields and can be unit-tested in isolation. Parsing is tolerant: keys may appear
/// in any order, casing/whitespace around the key and colon is ignored, unknown lines are
/// dropped, and any missing key falls back to `Self.notReported` rather than failing.
struct WoundFindingsParser {

    /// Placeholder for a field the VLM did not report at all (key absent from the output).
    /// Distinct from the model explicitly answering "Not visible", which is a real observation
    /// and is preserved verbatim.
    static let notReported = "Not reported"

    /// The canonical keys the VLM is asked to emit, mapped to a `WoundLogEntry` field.
    /// Matching against a line's key is case-insensitive and ignores surrounding whitespace.
    enum Field: String, CaseIterable {
        case stomaColor = "STOMA_COLOR"
        case stomaSizeChange = "STOMA_SIZE_CHANGE"
        case surroundingSkin = "SURROUNDING_SKIN"
        case outputAppearance = "OUTPUT_APPEARANCE"
        case bagSeal = "BAG_SEAL"
        case swellingOrProtrusion = "SWELLING_OR_PROTRUSION"
        case otherObservations = "OTHER"
    }

    struct ParsedFindings {
        let stomaColor: String
        let stomaSizeChange: String
        let surroundingSkin: String
        let outputAppearance: String
        let bagSeal: String
        let swellingOrProtrusion: String
        let otherObservations: String
        let flaggedForReview: Bool
    }

    /// Concerning signs that flag an entry for clinician review. Matched case-insensitively as
    /// substrings against the whole findings text. Intentionally conservative — this is a
    /// triage hint, not a diagnosis; a false positive costs a needless review, a false negative
    /// is worse, so the list favors recall.
    private static let reviewKeywords: [String] = [
        // Stoma ischemia / necrosis colors — a healthy stoma is pink/red.
        "dark", "black", "purple", "blue", "grey", "gray", "dusky", "pale", "necro",
        // Infection / breakdown signs.
        "pus", "purulent", "foul", "bleed", "blood", "infect",
        "significant swelling", "severe swelling", "marked swelling",
        "retract", "detach", "leak"
    ]

    static func parse(_ findings: String) -> ParsedFindings {
        var values: [Field: String] = [:]

        for rawLine in findings.split(whereSeparator: \.isNewline) {
            guard let colonIndex = rawLine.firstIndex(of: ":") else { continue }
            let keyPart = rawLine[..<colonIndex]
                .trimmingCharacters(in: .whitespaces)
                // Tolerate list markers the model may prepend, e.g. "- STOMA_COLOR: ..." or "* ...".
                .trimmingCharacters(in: CharacterSet(charactersIn: "-*• "))
                .uppercased()
            guard let field = Field(rawValue: keyPart) else { continue }

            let value = rawLine[rawLine.index(after: colonIndex)...]
                .trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            // First occurrence wins — a repeated key from a chatty model doesn't clobber it.
            if values[field] == nil {
                values[field] = value
            }
        }

        func value(_ field: Field) -> String { values[field] ?? notReported }

        return ParsedFindings(
            stomaColor: value(.stomaColor),
            stomaSizeChange: value(.stomaSizeChange),
            surroundingSkin: value(.surroundingSkin),
            outputAppearance: value(.outputAppearance),
            bagSeal: value(.bagSeal),
            swellingOrProtrusion: value(.swellingOrProtrusion),
            otherObservations: value(.otherObservations),
            flaggedForReview: shouldFlagForReview(findings)
        )
    }

    /// True if the findings text mentions any concerning sign. Case-insensitive substring match.
    static func shouldFlagForReview(_ findings: String) -> Bool {
        let haystack = findings.lowercased()
        return reviewKeywords.contains { haystack.contains($0) }
    }
}
