import Foundation
import CoreML

final class QueryEmbedder {
    private let model: MLModel
    private let inputName: String
    private let outputName: String

    init?(modelName: String = "query_embedder", inputName: String? = nil, outputName: String? = nil) {
        guard let url = Bundle.main.url(forResource: modelName, withExtension: "mlpackage")
            ?? Bundle.main.url(forResource: modelName, withExtension: "mlmodelc") else {
            return nil
        }

        do {
            model = try MLModel(contentsOf: url)
        } catch {
            return nil
        }

        let inputKeys = Array(model.modelDescription.inputDescriptionsByName.keys)
        let outputKeys = Array(model.modelDescription.outputDescriptionsByName.keys)

        self.inputName = inputName ?? inputKeys.first ?? "text"
        self.outputName = outputName ?? outputKeys.first ?? "embedding"

        guard model.modelDescription.inputDescriptionsByName[self.inputName]?.type == .string else {
            return nil
        }
    }

    func embed(_ text: String) -> [Float]? {
        guard let input = try? MLDictionaryFeatureProvider(dictionary: [inputName: text]) else {
            return nil
        }
        guard let output = try? model.prediction(from: input),
              let value = output.featureValue(for: outputName)?.multiArrayValue else {
            return nil
        }
        return toFloatArray(value)
    }

    private func toFloatArray(_ array: MLMultiArray) -> [Float]? {
        let count = array.count
        var result: [Float] = []
        result.reserveCapacity(count)

        switch array.dataType {
        case .float32:
            let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: count)
            for index in 0..<count {
                result.append(ptr[index])
            }
        case .double:
            let ptr = array.dataPointer.bindMemory(to: Double.self, capacity: count)
            for index in 0..<count {
                result.append(Float(ptr[index]))
            }
        default:
            return nil
        }

        return result
    }
}
