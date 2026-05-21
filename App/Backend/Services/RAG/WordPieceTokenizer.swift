import Foundation

/// Minimal WordPiece tokenizer matching BERT/BGE-small tokenisation.
/// Requires vocab.txt bundled as an app resource (one token per line, index = token ID).
final class WordPieceTokenizer {

    private let vocab: [String: Int32]
    private let maxSeqLen: Int

    private let padID:  Int32 = 0
    private let unkID:  Int32 = 100
    private let clsID:  Int32 = 101
    private let sepID:  Int32 = 102

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
        let wordTokens = wordPieceIDs(for: text.lowercased())

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

    // MARK: - Private

    private func wordPieceIDs(for text: String) -> [Int32] {
        basicTokenize(text).flatMap { tokenizeWord($0) }
    }

    /// Split on whitespace and isolate punctuation characters.
    private func basicTokenize(_ text: String) -> [String] {
        var words: [String] = []
        var buf = ""

        for ch in text {
            if ch.isWhitespace {
                if !buf.isEmpty { words.append(buf); buf = "" }
            } else if isPunct(ch) {
                if !buf.isEmpty { words.append(buf); buf = "" }
                words.append(String(ch))
            } else {
                buf.append(ch)
            }
        }
        if !buf.isEmpty { words.append(buf) }
        return words
    }

    /// Classic WordPiece greedy longest-match-first.
    private func tokenizeWord(_ word: String) -> [Int32] {
        if word.isEmpty { return [] }
        if let id = vocab[word] { return [id] }

        var ids:  [Int32] = []
        var start = word.startIndex

        while start < word.endIndex {
            var end       = word.endIndex
            var found: (String, Int32)?

            while start < end {
                let sub    = String(word[start..<end])
                let lookup = start == word.startIndex ? sub : "##" + sub
                if let id = vocab[lookup] {
                    found = (lookup, id)
                    break
                }
                end = word.index(before: end)
            }

            guard let (_, id) = found else { return [unkID] }
            ids.append(id)
            start = end
        }

        return ids
    }

    private func isPunct(_ ch: Character) -> Bool {
        ch.isPunctuation || ch.isSymbol || ch == "," || ch == "." ||
        ch == "!" || ch == "?" || ch == ";" || ch == ":"
    }
}
