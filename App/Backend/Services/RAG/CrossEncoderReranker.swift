import CoreML
import Foundation

/// On-device cross-encoder reranker (`cross-encoder/ms-marco-MiniLM-L6-v2`, converted to CoreML).
///
/// Hybrid retrieval ranks a chunk from the right document into the top five for most golden
/// questions but the exact gold chunk far less often: candidates are found, then ordered badly.
/// A cross-encoder reads the query and each candidate together and scores relevance directly, so
/// `SQLiteRetriever` retrieves `InferenceTuning.prompt.rerankCandidates` rows and keeps the best
/// `topK` by this score. Measured effect and latency: Docs/BE/Reranker.md.
///
/// Bundle resources, produced by `Pipeline/tools/convert_reranker.py`:
///   reranker.mlpackage — one relevance logit per `[CLS] query [SEP] passage [SEP]`
///   vocab.txt          — shared with `QueryEmbedder` (both use the bert-base-uncased vocabulary)
///
/// When either resource is missing `init` returns nil and retrieval keeps the fused order.
/// `CrossEncoderRerankerTests` checks pair encoding and scores against the exported fixture.
final class CrossEncoderReranker {

    static let maxSeqLen = 512

    private static let clsID: Int32 = 101
    private static let sepID: Int32 = 102
    private static let padID: Int32 = 0

    private let model: MLModel
    private let tokenizer: WordPieceTokenizer
    // Serializes prediction: the reranker is reached through the single shared SQLiteRetriever.
    private let predictionLock = NSLock()

    init?() {
        guard
            let modelURL = Bundle.main.url(forResource: "reranker", withExtension: "mlmodelc")
                ?? Bundle.main.url(forResource: "reranker", withExtension: "mlpackage"),
            let vocabURL = Bundle.main.url(forResource: "vocab", withExtension: "txt"),
            let tokenizer = WordPieceTokenizer(vocabURL: vocabURL, maxSeqLen: Self.maxSeqLen),
            let model = try? MLModel(contentsOf: modelURL)
        else {
            return nil
        }
        self.model = model
        self.tokenizer = tokenizer
    }

    // MARK: - Public

    /// Indices of `passages`, most relevant first, or nil when any prediction fails (the caller
    /// then keeps retrieval order rather than acting on a partial scoring).
    func rankedIndices(query: String, passages: [String]) -> [Int]? {
        let queryIDs = tokenizer.wordPieceIDs(for: query)
        var scores: [Float] = []
        scores.reserveCapacity(passages.count)
        for passage in passages {
            let encoding = Self.encodePair(query: queryIDs, passage: tokenizer.wordPieceIDs(for: passage))
            guard let score = predict(encoding) else { return nil }
            scores.append(score)
        }
        return Self.order(byScores: scores)
    }

    /// Relevance logit for one pair; exposed for the parity test.
    func score(query: String, passage: String) -> Float? {
        predict(Self.encodePair(
            query: tokenizer.wordPieceIDs(for: query),
            passage: tokenizer.wordPieceIDs(for: passage)
        ))
    }

    // MARK: - Pure pieces (tested directly)

    struct PairEncoding: Equatable {
        let inputIDs: [Int32]
        let tokenTypeIDs: [Int32]
        let attentionMask: [Int32]
    }

    /// `[CLS] query [SEP] passage [SEP]`, padded to `maxSeqLen`. Over-long pairs are truncated as
    /// the Hugging Face tokenizer's `longest_first` does it for a pair: a side no longer than half
    /// the room is kept whole and the other takes the rest; when both are longer, the shorter side
    /// (the query on a tie) gets the floor of half and the longer side the remainder.
    static func encodePair(query: [Int32], passage: [Int32], maxSeqLen: Int = maxSeqLen) -> PairEncoding {
        var query = query
        var passage = passage
        let room = maxSeqLen - 3
        if query.count + passage.count > room {
            let half = room / 2
            if query.count <= passage.count {
                query = Array(query.prefix(half))
                passage = Array(passage.prefix(room - query.count))
            } else {
                passage = Array(passage.prefix(half))
                query = Array(query.prefix(room - passage.count))
            }
        }
        let ids = [clsID] + query + [sepID] + passage + [sepID]
        let types = [Int32](repeating: 0, count: query.count + 2) + [Int32](repeating: 1, count: passage.count + 1)
        let padding = maxSeqLen - ids.count
        return PairEncoding(
            inputIDs: ids + [Int32](repeating: padID, count: padding),
            tokenTypeIDs: types + [Int32](repeating: 0, count: padding),
            attentionMask: [Int32](repeating: 1, count: ids.count) + [Int32](repeating: 0, count: padding)
        )
    }

    /// Indices best first; ties keep their original (retrieval) order, so a flat scoring never
    /// reshuffles what fusion ranked. Mirrors `eval/reranker.py::order_by_scores`.
    static func order(byScores scores: [Float]) -> [Int] {
        scores.indices.sorted { a, b in
            scores[a] != scores[b] ? scores[a] > scores[b] : a < b
        }
    }

    // MARK: - Private

    private func predict(_ encoding: PairEncoding) -> Float? {
        guard
            let ids = Self.multiArray(encoding.inputIDs),
            let types = Self.multiArray(encoding.tokenTypeIDs),
            let mask = Self.multiArray(encoding.attentionMask),
            let input = try? MLDictionaryFeatureProvider(dictionary: [
                "input_ids": MLFeatureValue(multiArray: ids),
                "token_type_ids": MLFeatureValue(multiArray: types),
                "attention_mask": MLFeatureValue(multiArray: mask),
            ])
        else { return nil }

        predictionLock.lock()
        let prediction = try? model.prediction(from: input)
        predictionLock.unlock()

        guard
            let output = prediction?.featureValue(for: "score")?.multiArrayValue,
            output.count >= 1,
            output.dataType == .float32
        else { return nil }
        return output[0].floatValue
    }

    private static func multiArray(_ values: [Int32]) -> MLMultiArray? {
        guard let array = try? MLMultiArray(shape: [1, NSNumber(value: values.count)], dataType: .int32) else {
            return nil
        }
        let pointer = array.dataPointer.bindMemory(to: Int32.self, capacity: values.count)
        for (index, value) in values.enumerated() {
            pointer[index] = value
        }
        return array
    }
}
