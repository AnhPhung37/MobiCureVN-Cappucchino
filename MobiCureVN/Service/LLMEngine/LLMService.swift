import Foundation

#if canImport(MLX) && canImport(MLXRandom) && canImport(MLXLMCommon) && canImport(MLXLLM) && canImport(MLXHuggingFace)
import MLX
import MLXRandom
import MLXLMCommon
import MLXLLM
import MLXHuggingFace
import HuggingFace
import Tokenizers
#endif

public final class LLMService: @unchecked Sendable {
    private let modelPath: String
    private let useMock: Bool
    
    #if canImport(MLX) && canImport(MLXLMCommon)
    private var modelProxy: ModelConfiguration?
    private var modelContainer: ModelContainer?
    #endif

    public init(modelPath: String = "mlx-community/Qwen2.5-7B-Instruct-4bit", pythonPath: String = "", useMock: Bool = false) {
        self.modelPath = modelPath
        self.useMock = useMock
        
        #if canImport(MLX) && canImport(MLXLMCommon)
        // Configure the environment to use the MLX model
        self.modelProxy = LLMRegistry.qwen2_5_7b
#endif
    }

    public func generate(prompt: String) -> AsyncStream<String> {
        return AsyncStream<String>(bufferingPolicy: .unbounded) { continuation in
            Task.detached(priority: .userInitiated) { [weak self] in
                guard let self = self else {
                    continuation.finish()
                    return
                }
                
                if self.useMock {
                    let reply = "I can share general information, but I cannot diagnose or prescribe. Consider consulting a clinician."
                    for chunk in Self.chunk(reply, size: 48) { continuation.yield(chunk) }
                    continuation.finish()
                    return
                }

                #if canImport(MLX) && canImport(MLXLMCommon)
                // --- 100% NATIVE SWIFT MLX IMPLEMENTATION ---
                // Setup device globals
                MLX.Device.setDefault(device: Device(.gpu))
                MLXRandom.seed(UInt64(Date().timeIntervalSince1970))
                
                do {
                    if self.modelContainer == nil {
                        guard let conf = self.modelProxy else {
                            continuation.yield("Could not resolve model config.")
                            continuation.finish()
                            return
                        }

                        self.modelContainer = try await LLMModelFactory.shared.loadContainer(
                            from: #hubDownloader(),
                            using: #huggingFaceTokenizerLoader(),
                            configuration: conf
                        )
                    }

                    guard let container = self.modelContainer else {
                        continuation.finish()
                        return
                    }

                    let session = ChatSession(container)
                    let response = try await session.respond(to: prompt)

                    continuation.yield(response)
                } catch {
                    continuation.yield("Native MLX Error: \(error.localizedDescription)")
                }
                #else
                continuation.yield("Error: This binary was compiled on a system without macOS/Apple Silicon MLX Frameworks.")
                #endif
                
                continuation.finish()
            }
        }
    }

    private static func chunk(_ text: String, size: Int) -> [String] {
        guard size > 0 else { return [text] }
        var chunks: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            chunks.append(String(text[start..<end]))
            start = end
        }
        return chunks
    }
}
