import Foundation

/// Counts of what the prefix cache did for eligible chat requests since the model was loaded.
/// Read by the device correctness test and the latency log; never used to make a decision.
nonisolated struct PrefixCacheStats: Sendable, Equatable {
    /// Prefilled from token zero: first turn, a turn after images, or no reusable prefix.
    var cold = 0
    /// Prefilled from token zero while keeping a copy of the shared prefix for later turns.
    var built = 0
    /// Resumed from a kept prefix.
    var reused = 0
    /// Prompt tokens not prefilled again because they were resumed.
    var reusedTokens = 0
}

/// The pure half of the prefix KV cache: whether a request may resume from a cached prompt prefix,
/// and from how many tokens. No MLX here, so every rule is unit-tested without a model.
///
/// Decisions are made on token ids of the full chat-templated prompt, never on strings: byte-stable
/// text is not token-stable across the prefix/suffix boundary (see Docs/BE/Prefix-KV-Cache.md).
nonisolated enum PrefixCachePlanner {

    enum Decision: Equatable, Sendable {
        /// Prefill the whole prompt, as every request did before the cache existed.
        case cold
        /// Resume from the kept prefix of this many tokens.
        case reuse(prefixLength: Int)
        /// Prefill this many shared tokens, keep a copy of that cache, then continue.
        case build(prefixLength: Int)
    }

    /// Below this a prefix is not worth a snapshot: the saving is under one prefill step and the
    /// kept cache still costs memory. The shipped system prompt's stable half is ~550 tokens.
    static let minimumPrefixTokens = 128

    /// Architectures whose resumed prefill was checked against mlx-swift-lm 3.31.3's source.
    ///
    /// - `qwen2`, `llama`, `phi3`, `gemma3_text` (MLXLLM): RoPE positions come from `cache.offset`
    ///   (`applyRotaryPosition`), so a seeded cache continues at the right positions.
    /// - `qwen3_5` (MLXVLM): its `prepare` resets rope state and numbers a text-only input from 0,
    ///   which is wrong on a seeded cache — resumption bypasses `prepare` (`PrefixResumingModel`)
    ///   and relies on text-only rope state, hence the media rule in `isEligible`.
    ///
    /// Anything else (e.g. `qwen2_5_vl`) is cold until checked the same way.
    static let resumableModelTypes: Set<String> = ["qwen2", "llama", "phi3", "gemma3_text", "qwen3_5"]

    static func commonPrefixLength(_ a: [Int], _ b: [Int]) -> Int {
        let limit = min(a.count, b.count)
        var length = 0
        while length < limit, a[length] == b[length] {
            length += 1
        }
        return length
    }

    /// Whether a request may use the cache at all.
    ///
    /// - Parameters:
    ///   - hasSystemPrompt: chat answers carry one; the auxiliary passes (classification,
    ///     rewrite, extraction) do not, so they neither use nor evict the chat prefix.
    ///   - hasMedia: images or video anywhere in the prompt (including replayed history).
    ///   - followsMedia: the previous generation on this model carried images. Qwen3.5 keeps rope
    ///     position state in the model between calls, and after an image turn that state is not the
    ///     text-only state a resumed prefill continues from.
    ///   - hasBoundedCache: `maxKVSize` gives rotating caches whose contents a snapshot cannot
    ///     represent faithfully once they wrap.
    static func isEligible(
        enabled: Bool,
        modelType: String?,
        hasSystemPrompt: Bool,
        hasMedia: Bool,
        followsMedia: Bool,
        hasBoundedCache: Bool
    ) -> Bool {
        guard enabled, hasSystemPrompt, !hasMedia, !followsMedia, !hasBoundedCache,
              let modelType else { return false }
        return resumableModelTypes.contains(modelType)
    }

    /// - Parameters:
    ///   - prompt: token ids of the full templated prompt for this request.
    ///   - cachedPrefix: token ids the kept cache was built from, if any.
    ///   - previousPrompt: token ids of the previous eligible request, used to discover the shared
    ///     prefix without ever tokenizing the prefix on its own.
    static func decide(
        prompt: [Int],
        cachedPrefix: [Int]?,
        previousPrompt: [Int]?,
        minimumPrefix: Int = minimumPrefixTokens
    ) -> Decision {
        // Resume only when the kept prefix is exactly the start of this prompt and at least one
        // token remains: the cache is never trimmed, because Qwen3.5's linear-attention layers keep
        // a recurrent state that cannot be rolled back.
        if let cachedPrefix,
           cachedPrefix.count >= minimumPrefix,
           cachedPrefix.count < prompt.count,
           commonPrefixLength(cachedPrefix, prompt) == cachedPrefix.count {
            return .reuse(prefixLength: cachedPrefix.count)
        }
        if let previousPrompt {
            let shared = commonPrefixLength(previousPrompt, prompt)
            if shared >= minimumPrefix, shared < prompt.count {
                return .build(prefixLength: shared)
            }
        }
        return .cold
    }
}
