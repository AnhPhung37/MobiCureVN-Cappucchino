import Foundation

/// Canonicalises text so guardrail pattern matching is resistant to trivial evasion.
///
/// The old checks were plain `lowercased().contains(pattern)`, which is defeated by
/// diacritics ("tự tử" vs "tu tu"), inserted punctuation ("t.ự.t.ử"), full-width or
/// zero-width characters, and irregular spacing. It also *under*-matches legitimate
/// Vietnamese input typed without diacritics (a very common real-world case), causing the
/// domain filter to wrongly reject medical questions.
///
/// Two canonical forms are produced from one pass:
///   • `canonical`  — folded + single-spaced. Used for domain/intent matching, where word
///                     boundaries matter and over-matching would reject valid questions.
///   • `compact`    — `canonical` with all spaces removed. Used for the hard blocklist
///                     (self-harm, jailbreak), where an adversary spaces characters out to
///                     slip past; here a missed block is worse than an occasional false hit.
enum GuardRailNormalizer {

    /// Folded, single-spaced form. `"Tự-Tử  NGAY"` → `"tu tu ngay"`.
    static func canonical(_ text: String) -> String {
        // NFKC compatibility mapping folds full-width / styled characters to plain ASCII.
        var s = text.precomposedStringWithCompatibilityMapping
        // đ/Đ are distinct Vietnamese letters, not d + a combining mark, so diacritic
        // folding leaves them untouched — map them explicitly before folding.
        s = s.replacingOccurrences(of: "đ", with: "d").replacingOccurrences(of: "Đ", with: "D")
        // Remove case, diacritics, and width in one locale-aware fold.
        s = s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                      locale: Locale(identifier: "en_US_POSIX"))
        // Everything that is not a-z / 0-9 becomes a space (strips zero-width chars,
        // punctuation, emoji, and combining leftovers), then collapse runs of spaces.
        let scalars = s.unicodeScalars.map { scalar -> Character in
            let c = Character(scalar)
            let isAlnum = ("a"..."z").contains(c) || ("0"..."9").contains(c)
            return isAlnum ? c : " "
        }
        return String(scalars)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    /// `canonical` with all spaces removed. `"t ự  t ử"` → `"tutu"`.
    static func compact(_ text: String) -> String {
        canonical(text).replacingOccurrences(of: " ", with: "")
    }

    // MARK: - Matching helpers

    /// Substring match on the canonical form. Keeps the old prefix-friendly behaviour
    /// (e.g. keyword "eat" still matches "eating") while gaining evasion resistance.
    /// `pattern` is assumed already canonical (patterns are normalised once at load).
    static func canonicalContains(_ canonicalText: String, canonicalPattern: String) -> Bool {
        guard !canonicalPattern.isEmpty else { return false }
        return canonicalText.contains(canonicalPattern)
    }

    /// True if any canonical pattern is a substring of the canonical text.
    static func matchesAny(canonicalText: String, canonicalPatterns: [String]) -> Bool {
        canonicalPatterns.contains { canonicalContains(canonicalText, canonicalPattern: $0) }
    }

    /// Blocklist match: try the canonical (spaced) form first, then the compact (de-spaced)
    /// form so character-spacing evasion is still caught. Returns the matched raw pattern.
    static func firstBlocklistMatch(
        canonicalText: String,
        compactText: String,
        patterns: [(raw: String, canonical: String, compact: String)]
    ) -> String? {
        for p in patterns {
            if !p.canonical.isEmpty && canonicalText.contains(p.canonical) { return p.raw }
            if !p.compact.isEmpty && compactText.contains(p.compact) { return p.raw }
        }
        return nil
    }
}
