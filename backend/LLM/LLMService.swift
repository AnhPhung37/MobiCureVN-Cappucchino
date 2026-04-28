import Foundation
#if canImport(MLX) && canImport(MLXLMCommon)
import MLX
import MLXLMCommon
import MLXRandom
#endif

public final class LLMService: @unchecked Sendable {
    private let modelPath: String
    private let useMock: Bool
    
    #if canImport(MLX) && canImport(MLXLMCommon)
    private var modelProxy: ModelConfiguration?
    private var loadedModel: LLMModel?
    private var tokenizers: [Tokenizer]?
    #endif

    public init(modelPath: String = "mlx-community/Qwen2.5-7B-Instruct-4bit", pythonPath: String = "", useMock: Bool = false) {
        self.modelPath = modelPath
        self.useMock = useMock
        
        #if canImport(MLX) && canImport(MLXLMCommon)
        // Configure the environment to use the MLX model
        self.modelProxy = ModelRegistry.modelIdentifier(for: modelPath)
        #endif
    }

    public func generate(prompt: String) -> AsyncStream<String> {
        AsyncStream { continuation in
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
                MLX.Device.setDefault(Device(network: .gpu))
                MLXRandom.seed(UInt64(Date().timeIntervalSince1970))
                
                do {
                    // Lazy-load the model from Hugging Face structure exclusively into Neural Engine / RAM once
                    if self.loadedModel == nil {
                        guard let conf = self.modelProxy else {
                            continuation.yield("Could not resolve model config.")
                            continuation.finish()
                            return
                        }
                        
                        let modelFactory = try await LLMModelFactory.shared.load(configuration: conf)
                        self.loadedModel = modelFactory.model
                        self.tokenizers = modelFactory.tokenizers
                    }
                    
                    guard let model = self.loadedModel, let tokenizer = self.tokenizers?.first else {
                        continuation.finish(); return
                    }
                    
                    // Tokenize the incoming prompt
                    let inputTokens = try tokenizer.encode(text: prompt)
                    
                    // Native MLX Generation setup
                    let generateParams = GenerateParameters(
                        temperature: 0.2,
                        maxTokens: 512
                    )
                    
                    // Run generation loop
                    let result = try await MLXLMCommon.generate(
                        promptTokens: inputTokens,
                        parameters: generateParams,
                        model: model,
                        tokenizer: tokenizer
                    ) { tokens in 
                        // You can stream tokens progressively here in a full app
                        return .more
                    }
                    
                    // Yield generated output back to ChatOrchestrator
                    if let finalOutput = result.output {
                        continuation.yield(finalOutput)
                    }
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
