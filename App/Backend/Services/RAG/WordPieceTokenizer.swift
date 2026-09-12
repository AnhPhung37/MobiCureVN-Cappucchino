import Foundation

/// WordPiece tokenizer for the bundled query embedder (BAAI/bge-small-en-v1.5).
///
/// It must produce exactly the token ids `transformers`' `BertTokenizerFast` produced for the
/// same text when the index was built: a different id sequence yields a different query vector,
/// and vector search then returns confident nonsense rather than an error. It therefore mirrors
/// the Hugging Face pipeline for this model code point by code point:
///
///   1. clean — drop NUL, U+FFFD and control/format characters (tab, LF and CR count as
///      whitespace); map every whitespace character to a space;
///   2. isolate CJK ideographs with spaces;
///   3. strip accents (NFD, drop non-spacing marks) and lowercase;
///   4. split on whitespace, and isolate punctuation — ASCII punctuation plus every Unicode
///      `P*` category, but NOT symbols such as `°` or `€`, which BERT keeps inside the word;
///   5. greedy longest-match-first WordPiece with the `##` continuation prefix, where a word of
///      more than 100 code points, or one with any unmatched piece, becomes a single `[UNK]`.
///
/// `QueryEmbedderParityTests` pins this against ids exported by `Pipeline/tools/convert_embedder.py`.
/// Requires vocab.txt bundled as an app resource (one token per line, index = token ID).
final class WordPieceTokenizer {

    private let vocab: [String: Int32]
    private let maxSeqLen: Int

    private let padID:  Int32 = 0
    private let unkID:  Int32 = 100
    private let clsID:  Int32 = 101
    private let sepID:  Int32 = 102

    /// `max_input_chars_per_word` in the Hugging Face WordPiece model.
    private let maxInputCharsPerWord = 100

    init?(vocabURL: URL, maxSeqLen: Int = 128) {
        guard let raw = try? String(contentsOf: vocabURL, encoding: .utf8) else { return nil }
        var v: [String: Int32] = [:]
        v.reserveCapacity(32_000)
        for (idx, line) in raw.components(separatedBy: "\n").enumerated() {
            let tok = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !tok.isEmpty { v[tok] = Int32(idx) }
        }
        guard !v.isEmpty else { return nil }
        self.vocab = v
        self.maxSeqLen = maxSeqLen
    }

    // MARK: - Public

    /// Returns (input_ids, attention_mask) each of length `maxSeqLen`, ready for CoreML.
    func tokenize(_ text: String) -> (inputIDs: [Int32], attentionMask: [Int32]) {
        let wordTokens = wordPieceIDs(for: text)

        // [CLS] + content (truncated) + [SEP]
        let maxContent = maxSeqLen - 2
        let content    = Array(wordTokens.prefix(maxContent))
        let ids        = [clsID] + content + [sepID]

        var inputIDs      = [Int32](repeating: padID, count: maxSeqLen)
        var attentionMask = [Int32](repeating: 0,     count: maxSeqLen)

        for (i, id) in ids.enumerated() {
            inputIDs[i]      = id
            attentionMask[i] = 1
        }

        return (inputIDs, attentionMask)
    }

    /// WordPiece ids for `text` without `[CLS]`/`[SEP]` or padding.
    func wordPieceIDs(for text: String) -> [Int32] {
        basicTokenize(text).flatMap { tokenizeWord($0) }
    }

    // MARK: - Basic tokenization

    private func basicTokenize(_ text: String) -> [[Unicode.Scalar]] {
        // 1 + 2: clean, and put spaces around CJK ideographs.
        var cleaned = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar.value == 0 || scalar.value == 0xFFFD || Self.isControl(scalar) { continue }
            if Self.isWhitespace(scalar) {
                cleaned.append(" ")
            } else if Self.isCJK(scalar) {
                cleaned.append(" ")
                cleaned.append(scalar)
                cleaned.append(" ")
            } else {
                cleaned.append(scalar)
            }
        }

        // 3: strip accents, then lowercase — per code point, as the Rust normalizer does.
        var normalized: [Unicode.Scalar] = []
        for scalar in String(cleaned).decomposedStringWithCanonicalMapping.unicodeScalars
        where scalar.properties.generalCategory != .nonspacingMark {
            normalized.append(contentsOf: scalar.properties.lowercaseMapping.unicodeScalars)
        }

        // 4: whitespace split, punctuation isolated.
        var words: [[Unicode.Scalar]] = []
        var current: [Unicode.Scalar] = []
        for scalar in normalized {
            if Self.isWhitespace(scalar) {
                if !current.isEmpty { words.append(current); current = [] }
            } else if Self.isPunctuation(scalar) {
                if !current.isEmpty { words.append(current); current = [] }
                words.append([scalar])
            } else {
                current.append(scalar)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    // MARK: - WordPiece

    /// Classic WordPiece greedy longest-match-first, over code points.
    private func tokenizeWord(_ word: [Unicode.Scalar]) -> [Int32] {
        if word.isEmpty { return [] }
        guard word.count <= maxInputCharsPerWord else { return [unkID] }

        var ids: [Int32] = []
        var start = 0
        while start < word.count {
            var end = word.count
            var match: Int32?
            while start < end {
                var piece = String(String.UnicodeScalarView(word[start..<end]))
                if start > 0 { piece = "##" + piece }
                if let id = vocab[piece] {
                    match = id
                    break
                }
                end -= 1
            }
            // One unmatched piece makes the whole word unknown, as in the reference implementation.
            guard let id = match else { return [unkID] }
            ids.append(id)
            start = end
        }
        return ids
    }

    // MARK: - Character classes (Hugging Face `tokenizers`, normalizers/bert.rs)

    private static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "\t" || scalar == "\n" || scalar == "\r" || scalar.properties.isWhitespace
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "\t" || scalar == "\n" || scalar == "\r" { return false }
        switch scalar.properties.generalCategory {
        case .control, .format, .unassigned, .privateUse, .surrogate: return true
        default: return false
        }
    }

    private static func isPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x21...0x2F, 0x3A...0x40, 0x5B...0x60, 0x7B...0x7E: return true
        default: break
        }
        switch scalar.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation:
            return true
        default:
            return false
        }
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2A6DF, 0x2A700...0x2B73F,
             0x2B740...0x2B81F, 0x2B820...0x2CEAF, 0xF900...0xFAFF, 0x2F800...0x2FA1F:
            return true
        default:
            return false
        }
    }
}
