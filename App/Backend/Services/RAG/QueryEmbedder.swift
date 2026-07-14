import Foundation
import CoreML

/// On-device query embedder backed by a CoreML-converted BGE-small model.
///
/// Requires two bundle resources added in Xcode:
///   query_embedder.mlpackage  — output of Pipeline/convert_embedder.py
///   vocab.txt                 — WordPiece vocabulary from the same script
///
/// When either resource is absent, init() returns nil and SQLiteRetriever
/// silently skips vector search, falling back to FTS-only retrieval.
final class QueryEmbedder {

    private let model:     MLModel
    private let tokenizer: WordPieceTokenizer
    private let maxSeqLen: Int = 128
    private let embedDim:  Int = 384
    // Serializes prediction: this embedder is reached through the single shared
    // SQLiteRetriever, which several tasks may touch. MLModel inference is treated as
    // not-reentrant here rather than relying on undocumented thread-safety.
    private let predictionLock = NSLock()

    init?() {
        guard
            let modelURL = Bundle.main.url(forResource: "query_embedder", withExtension: "mlpackage")
                        ?? Bundle.main.url(forResource: "query_embedder", withExtension: "mlmodelc"),
            let vocabURL = Bundle.main.url(forResource: "vocab", withExtension: "txt")
        else {
            return nil
        }

        guard let tok = WordPieceTokenizer(vocabURL: vocabURL, maxSeqLen: maxSeqLen) else {
            return nil
        }

        do {
            model = try MLModel(contentsOf: modelURL)
        } catch {
            return nil
        }

        self.tokenizer = tok
    }

    // MARK: - Public

    func embed(_ text: String) -> [Float]? {
        let (inputIDs, attentionMask) = tokenizer.tokenize(text)

        guard
            let inputIDsArray      = try? MLMultiArray(shape: [1, NSNumber(value: maxSeqLen)], dataType: .int32),
            let attentionMaskArray = try? MLMultiArray(shape: [1, NSNumber(value: maxSeqLen)], dataType: .int32)
        else { return nil }

        for i in 0..<maxSeqLen {
            inputIDsArray[i]      = NSNumber(value: inputIDs[i])
            attentionMaskArray[i] = NSNumber(value: attentionMask[i])
        }

        guard
            let input = try? MLDictionaryFeatureProvider(dictionary: [
                "input_ids":      MLFeatureValue(multiArray: inputIDsArray),
                "attention_mask": MLFeatureValue(multiArray: attentionMaskArray),
            ])
        else { return nil }

        predictionLock.lock()
        let prediction = try? model.prediction(from: input)
        predictionLock.unlock()

        guard
            let output = prediction,
            let multiArray = output.featureValue(for: "embedding")?.multiArrayValue
        else { return nil }

        return toFloatArray(multiArray)
    }

    // MARK: - Private

    private func toFloatArray(_ array: MLMultiArray) -> [Float]? {
        let count = array.count
        guard count == embedDim else { return nil }
        var result = [Float](repeating: 0, count: count)

        switch array.dataType {
        case .float32:
            let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: count)
            for i in 0..<count { result[i] = ptr[i] }
        case .double:
            let ptr = array.dataPointer.bindMemory(to: Double.self, capacity: count)
            for i in 0..<count { result[i] = Float(ptr[i]) }
        default:
            return nil
        }

        return result
    }
}
