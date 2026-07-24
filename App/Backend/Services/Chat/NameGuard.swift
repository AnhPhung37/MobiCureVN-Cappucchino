import Foundation

/// Preserves a user's name **exactly as they typed it** across the LLM pipeline.
///
/// Two observed failures motivate this, both from the small on-device model treating a proper
/// name as ordinary text to "improve":
///   1. Refine corruption — `refine("I'm hanh")` returned `"Haven't"`: the model read the
///      unfamiliar token as a typo and rewrote it into a word it knew.
///   2. Output re-accenting — a Vietnamese translation turned the stored name "Hanh" into
///      "Hạnh", silently adding diacritics the user never wrote. For a name, "close" is wrong:
///      it is the user's own name and must round-trip byte-for-byte.
///
/// Strategy: a **pin + protect + restore** cycle around every LLM text transform.
///   • `detectName` finds the name token in the RAW input, before refine sees it, using simple
///     self-introduction patterns ("I'm X", "my name is X", "tôi là X", "tôi tên X"). It is a
///     cheap deterministic pass, not an LLM call — a missed name simply isn't pinned (the old
///     behaviour), never a wrong one.
///   • `protect` swaps the pinned name for an opaque sentinel the model won't rewrite, so
///     refine/translate operate around it. `restore` swaps the exact original spelling back in.
///
/// The pinned name is the literal substring from the user's text — never the model's echo of
/// it — so the spelling the user typed is the spelling that survives.
struct NameGuard {

    /// An opaque placeholder that the LLM will pass through untouched (no diacritics to "fix",
    /// no typo to "correct"). Chosen to be inert across refine and translation prompts.
    private static let sentinel = "\u{2063}NAME\u{2063}" // wrapped in INVISIBLE SEPARATOR

    // Self-introduction lead-ins, longest/most-specific first so "my name is" wins over "is".
    // English and Vietnamese, matching the two supported input languages. Kept intentionally
    // small and high-precision: these phrases overwhelmingly precede an actual name.
    private static let introPatterns = [
        "my name is", "i am called", "i'm called", "call me",
        "tên tôi là", "tôi tên là", "tôi tên", "tôi là", "mình tên là", "mình tên", "mình là",
        "i'm", "i am"
    ]

    /// Extracts the name token from raw user input, or `nil` if the turn isn't a
    /// self-introduction. Returns the name **exactly as typed** (original case and accents).
    ///
    /// Deliberately conservative: it only fires on an explicit introduction lead-in followed by
    /// a single capitalised-or-plain word, so ordinary sentences that merely start with "I'm
    /// tired" don't capture "tired" as a name. A trailing word that is a common state/adjective
    /// ("tired", "fine", "ok", "here") is rejected.
    func detectName(in rawText: String) -> String? {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let lower = text.lowercased()

        for pattern in Self.introPatterns {
            guard let range = lower.range(of: pattern) else { continue }
            // Require the lead-in to be at a word boundary at its start, so "I'm" doesn't match
            // inside another word. (Patterns end at a natural space before the name.)
            let before = range.lowerBound == lower.startIndex
                ? " "
                : String(lower[lower.index(before: range.lowerBound)])
            guard before == " " || before == "," || before == "." else { continue }

            // Map the match back into the ORIGINAL-case string to preserve the name's spelling.
            let offset = lower.distance(from: lower.startIndex, to: range.upperBound)
            let afterIdx = text.index(text.startIndex, offsetBy: offset)
            let remainder = text[afterIdx...].trimmingCharacters(in: .whitespacesAndNewlines)

            if let name = Self.firstNameToken(remainder) { return name }
        }
        return nil
    }

    /// Replaces every occurrence of `name` in `text` with the inert sentinel, so an LLM
    /// transform can't alter it. Case-insensitive match; returns text unchanged if `name` is
    /// absent (e.g. the transform input no longer contains it).
    func protect(_ text: String, name: String?) -> String {
        guard let name, !name.isEmpty else { return text }
        return text.replacingOccurrences(
            of: name, with: Self.sentinel, options: [.caseInsensitive]
        )
    }

    /// Swaps every sentinel back to the exact pinned `name`. Safe to call when no sentinel is
    /// present (returns text unchanged), so restore can run unconditionally after a transform.
    func restore(_ text: String, name: String?) -> String {
        guard let name, !name.isEmpty else { return text }
        return text.replacingOccurrences(of: Self.sentinel, with: name)
    }

    // MARK: - Private

    // Words that follow a self-intro lead-in but are clearly NOT names — states, feelings, and
    // filler the user might say ("I'm tired", "I'm fine", "I am here"). Rejecting these keeps
    // detection precise. Lowercased for membership tests.
    private static let nonNameWords: Set<String> = [
        "tired", "fine", "ok", "okay", "good", "great", "well", "here", "sick", "hurt",
        "hurting", "sorry", "not", "so", "very", "still", "back", "better", "worse", "in",
        "at", "on", "the", "a", "an", "feeling", "doing", "just", "really"
    ]

    /// First word token of `remainder`, stripped of trailing punctuation, or `nil` if it's
    /// empty or a known non-name filler word. Preserves the token's original spelling/case.
    private static func firstNameToken(_ remainder: String) -> String? {
        let token = remainder
            .split(whereSeparator: { $0 == " " || $0 == "," || $0 == "." || $0 == "!" || $0 == "?" })
            .first
            .map(String.init)
        guard let token, !token.isEmpty else { return nil }
        // A name is a single word of letters (allowing Vietnamese diacritics via isLetter).
        guard token.allSatisfy({ $0.isLetter }) else { return nil }
        guard !nonNameWords.contains(token.lowercased()) else { return nil }
        return token
    }
}
