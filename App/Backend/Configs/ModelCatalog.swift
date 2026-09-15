import Foundation

/// Catalog of supported on-device MLX models.
/// To try a new model, add a case here — everything else reads from this enum.
nonisolated enum ModelCatalog: String, CaseIterable {
    case qwen3_5_4B    = "mlx-community/Qwen3.5-4B-4bit"
    case qwen2_5_3B    = "mlx-community/Qwen2.5-3B-Instruct-4bit"
    case llama3_2_3B   = "mlx-community/Llama-3.2-3B-Instruct-4bit"
    case phi3_5Mini    = "mlx-community/Phi-3.5-mini-instruct-4bit"
    case gemma3_1B     = "mlx-community/gemma-3-1b-it-4bit"
    case qwen2_5_VL_3B = "mlx-community/Qwen2.5-VL-3B-Instruct-4bit"
    case qwen2_5_VL_7B = "mlx-community/Qwen2.5-VL-7B-Instruct-4bit"
    case medgemma1_5_4B = "mlx-community/medgemma-1.5-4b-it-4bit"
    case gemma4_E2B    = "mlx-community/gemma-4-e2b-it-4bit"

    /// Qwen 3.5 4B: accuracy-first default — strongest Vietnamese fluency/reasoning in the
    /// catalog, natively multimodal (wound photos), 262K context that comfortably holds RAG
    /// citations. NOTE: changing the default makes existing installs without an explicit
    /// model selection download this model on next launch (~2.4 GB).
    static let `default`: ModelCatalog = .qwen3_5_4B

    var repoID: String { rawValue }

    /// Measured tokens per whitespace word for this model's tokenizer — the multiplier the
    /// prompt budgets use (`MedicalChatOrchestrator.estimateTokens`) unless
    /// `InferenceTuning.prompt.wordsToTokensRatio` pins one.
    ///
    /// Per model: the aggregate over the 1238-chunk corpus as formatted into the prompt, or the
    /// Vietnamese figure where that is higher, rounded up to 0.05 — so a budget is a ceiling on
    /// that model in either language the history carries. Reproduce with
    /// `Pipeline/tools/measure_token_ratio.py`; a new case needs its own measurement.
    /// MedGemma 1.5 and Gemma 4 E2B were measured on the 1876-chunk split corpus (EN formatted
    /// 1.693, VI 1.204 for both — the Gemma vocabulary); see Docs/BE/Model-Catalog-Candidates.md.
    var wordsToTokensRatio: Double {
        switch self {
        case .qwen3_5_4B:    return 1.75
        case .qwen2_5_3B:    return 1.70
        case .llama3_2_3B:   return 1.65
        case .phi3_5Mini:    return 2.85
        case .gemma3_1B:     return 1.70
        case .qwen2_5_VL_3B: return 1.70
        case .qwen2_5_VL_7B: return 1.70
        case .medgemma1_5_4B: return 1.70
        case .gemma4_E2B:    return 1.70
        }
    }

    /// Vision-language models accept images attached to chat messages; text-only
    /// models silently drop them. Loading goes through VLMModelFactory for these.
    var supportsVision: Bool {
        switch self {
        // MedGemma 1.5 exports as `gemma3` and Gemma 4 E2B as `gemma4`: both carry the vision
        // tower and load through VLMModelFactory (LLMService.visionModelTypes).
        case .qwen3_5_4B, .qwen2_5_VL_3B, .qwen2_5_VL_7B, .medgemma1_5_4B, .gemma4_E2B: return true
        default: return false
        }
    }

    /// Approximate on-disk size of the 4-bit weights, shown in the model picker so the
    /// user knows how large the download is before selecting a model.
    var approxDownloadSize: String {
        switch self {
        case .qwen3_5_4B:    return "~2.4 GB"
        case .qwen2_5_3B:    return "~1.8 GB"
        case .llama3_2_3B:   return "~1.8 GB"
        case .phi3_5Mini:    return "~2.2 GB"
        case .gemma3_1B:     return "~0.8 GB"
        case .qwen2_5_VL_3B: return "~2.2 GB"
        case .qwen2_5_VL_7B: return "~4.5 GB"
        case .medgemma1_5_4B: return "~3.4 GB"
        // E2B's per-layer embeddings keep the 4-bit download near a 4B model despite ~2B
        // effective parameters.
        case .gemma4_E2B:    return "~3.6 GB"
        }
    }

    /// Compact name shown next to the picker in the top bar, where the full
    /// displayName (with quantization/vision suffix) would not fit.
    var shortName: String {
        switch self {
        case .qwen3_5_4B:    return "Qwen 3.5 4B"
        case .qwen2_5_3B:    return "Qwen 2.5 3B"
        case .llama3_2_3B:   return "Llama 3.2 3B"
        case .phi3_5Mini:    return "Phi 3.5 Mini"
        case .gemma3_1B:     return "Gemma 3 1B"
        case .qwen2_5_VL_3B: return "Qwen 2.5 VL 3B"
        case .qwen2_5_VL_7B: return "Qwen 2.5 VL 7B"
        case .medgemma1_5_4B: return "MedGemma 1.5 4B"
        case .gemma4_E2B:    return "Gemma 4 E2B"
        }
    }

    var displayName: String {
        switch self {
        case .qwen3_5_4B:    return "Qwen 3.5 4B (4-bit, vision)"
        case .qwen2_5_3B:    return "Qwen 2.5 3B (4-bit)"
        case .llama3_2_3B:   return "Llama 3.2 3B (4-bit)"
        case .phi3_5Mini:    return "Phi 3.5 Mini (4-bit)"
        case .gemma3_1B:     return "Gemma 3 1B (4-bit)"
        case .qwen2_5_VL_3B: return "Qwen 2.5 VL 3B (4-bit, vision)"
        case .qwen2_5_VL_7B: return "Qwen 2.5 VL 7B (4-bit, vision)"
        case .medgemma1_5_4B: return "MedGemma 1.5 4B (4-bit, vision)"
        case .gemma4_E2B:    return "Gemma 4 E2B (4-bit, vision)"
        }
    }
}
