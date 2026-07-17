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

    /// Qwen 3.5 4B: accuracy-first default — strongest Vietnamese fluency/reasoning in the
    /// catalog, natively multimodal (wound photos), 262K context that comfortably holds RAG
    /// citations. NOTE: changing the default makes existing installs without an explicit
    /// model selection download this model on next launch (~2.4 GB).
    static let `default`: ModelCatalog = .qwen3_5_4B

    var repoID: String { rawValue }

    /// Vision-language models accept images attached to chat messages; text-only
    /// models silently drop them. Loading goes through VLMModelFactory for these.
    var supportsVision: Bool {
        switch self {
        case .qwen3_5_4B, .qwen2_5_VL_3B, .qwen2_5_VL_7B: return true
        default: return false
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
        }
    }
}
