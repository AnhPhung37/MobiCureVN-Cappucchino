#if canImport(MLXLLM)
import Foundation
import MLX
import MLXLMCommon
import MLXNN

/// A kept KV cache for the first `tokens.count` tokens of an earlier prompt.
///
/// Immutable after creation — readers only `copy()` the cache — which is what makes the unchecked
/// `Sendable` sound. Guarded in `LLMService` by `stateLock`.
final class PrefixSnapshot: @unchecked Sendable {
    let tokens: [Int]
    let cache: [KVCache]

    init(tokens: [Int], cache: [KVCache]) {
        self.tokens = tokens
        self.cache = cache
    }
}

/// Lets `TokenIterator` continue from a seeded cache instead of prefilling from token zero.
///
/// `TokenIterator` always starts with `model.prepare`. For text LLMs that already works on a seeded
/// cache, but Qwen3.5's `prepare` resets its rope position state and numbers a text-only input from
/// 0, so the suffix would be embedded at the wrong positions — a silent failure, fluent wrong text.
/// This wrapper prefills the suffix through `callAsFunction` instead, which numbers positions from
/// `cache.offset` for every architecture in `PrefixCachePlanner.resumableModelTypes`. Everything
/// else forwards to the wrapped model.
final class PrefixResumingModel: Module, LanguageModel {
    private let base: any LanguageModel

    init(_ base: any LanguageModel) {
        self.base = base
        super.init()
    }

    func prepare(_ input: LMInput, cache: [KVCache], windowSize: Int?) throws -> PrepareResult {
        let tokens = PrefixKV.batched(input.text.tokens)
        let length = tokens.dim(1)
        let step = max(1, windowSize ?? 512)
        var output: LMOutput?
        var start = 0
        while start < length {
            let end = min(start + step, length)
            output = base.callAsFunction(
                LMInput.Text(tokens: tokens[0..., start ..< end]), cache: cache, state: nil
            )
            if end < length {
                eval(cache)
            }
            start = end
        }
        guard let output else { throw PrefixKV.Failure.emptySuffix }
        return .logits(output)
    }

    func callAsFunction(_ input: LMInput.Text, cache: [KVCache]?, state: LMOutput.State?) -> LMOutput {
        base.callAsFunction(input, cache: cache, state: state)
    }

    func newCache(parameters: GenerateParameters?) -> [KVCache] {
        base.newCache(parameters: parameters)
    }
}

enum PrefixKV {

    enum Failure: Error {
        case emptySuffix
    }

    /// Token ids of a processor's output, whether it is shaped `[L]` (MLXLLM) or `[1, L]` (MLXVLM).
    static func tokenIDs(_ tokens: MLXArray) -> [Int] {
        tokens.reshaped([-1]).asType(.int32).asArray(Int32.self).map(Int.init)
    }

    static func batched(_ tokens: MLXArray) -> MLXArray {
        tokens.ndim == 1 ? tokens[.newAxis, 0...] : tokens
    }

    /// Tokens `start..<end` of `text`, keeping its rank and slicing a matching mask.
    static func slice(_ text: LMInput.Text, from start: Int, to end: Int?) -> LMInput.Text {
        let stop = end ?? text.tokens.dim(-1)
        if text.tokens.ndim == 2 {
            return LMInput.Text(
                tokens: text.tokens[0..., start ..< stop],
                mask: text.mask.map { $0.ndim == 2 ? $0[0..., start ..< stop] : $0 }
            )
        }
        return LMInput.Text(
            tokens: text.tokens[start ..< stop],
            mask: text.mask.map { $0[start ..< stop] }
        )
    }

    /// A fresh cache holding exactly `prefix`.
    ///
    /// Goes through the model's own `prepare` on an empty cache — the path every cold request takes
    /// — so Qwen3.5 records text-only rope state. MLXLLM's `prepare` leaves up to one prefill step
    /// unevaluated; that remainder is fed here so the cache covers every prefix token.
    static func seed(model: any LanguageModel, prefix: LMInput.Text, parameters: GenerateParameters) throws
        -> [KVCache]
    {
        let cache = model.newCache(parameters: parameters)
        switch try model.prepare(LMInput(text: prefix), cache: cache, windowSize: parameters.prefillStepSize) {
        case .logits:
            break
        case .tokens(let remainder):
            if remainder.tokens.size > 0 {
                _ = model.callAsFunction(
                    LMInput.Text(tokens: batched(remainder.tokens)), cache: cache, state: nil
                )
            }
        }
        eval(cache)
        return cache
    }
}
#endif
