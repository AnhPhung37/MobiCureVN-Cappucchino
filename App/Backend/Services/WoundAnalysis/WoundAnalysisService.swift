import Foundation

/// Runs a small vision-language model over wound/stoma photos to extract structured visual
/// findings, as a pre-step feeding into the existing `MedicalChatOrchestrator` pipeline (RAG →
/// LLM → guardrails run unchanged afterward; this only produces the text that drives them).
///
/// Only one multi-GB MLX model may be resident at a time on a 16GB iPad Air — the same
/// constraint `AppConfig.switchModel` enforces for manual model switching. This service borrows
/// that unload-then-load sequencing directly rather than calling `AppConfig.switchModel`, because
/// that function fires a detached background `Task` and returns before the model is actually
/// loaded; this flow needs to `await` each swap so the text-model reload is guaranteed complete
/// before the caller hands off to the orchestrator.
@MainActor
final class WoundAnalysisService {

    private static let woundVLM: ModelCatalog = .qwen2_5_VL_3B

    private static let findingsSystemPrompt = """
    You are a visual observation tool. Describe ONLY what is visible in the photo:
    - Redness: location and extent
    - Swelling: location and extent
    - Discharge: presence, color, consistency
    - Wound margins: shape, definition (well-defined vs. irregular)
    - Surrounding skin: color, texture changes

    Output as a short structured list, one line per finding. If a finding is not visible or
    not applicable, write "Not visible" for that line — do not guess.

    Do NOT diagnose. Do NOT assess infection risk. Do NOT recommend treatment. Only describe
    what is visually present in the image.
    """

    /// Runs the VLM over the attached photo(s) and returns its structured findings text.
    ///
    /// Sequencing: unloads whatever model is currently resident in `AppConfig.llmService`,
    /// loads the wound VLM and awaits it, runs inference, unloads the VLM, then reloads
    /// `AppConfig.selectedModel` (the user's chosen text model) and awaits that too before
    /// returning — so by the time this call completes, `AppConfig.llmService` is back to a
    /// ready, resident text model and the caller can safely run a normal `processQuery`.
    static func analyzeWound(images: [Data]) async -> String {
        guard !images.isEmpty else { return "" }

        let previousModel = AppConfig.selectedModel

        guard let vlmService = await loadModel(Self.woundVLM) else {
            // Download/load failed — restore the previous text model before giving up so the
            // app isn't left with no resident model.
            _ = await loadModel(previousModel)
            return ""
        }

        let request = LLMRequest(
            systemPrompt: Self.findingsSystemPrompt,
            userMessage: "Describe the visual findings in this photo.",
            images: images
        )
        let findings = await accumulate(stream: vlmService.stream(request: request))
        vlmService.unload()

        _ = await loadModel(previousModel)

        return findings
    }

    /// Unloads the currently-resident model (if real), downloads/loads `model`, awaits
    /// `initializeModel()`, and publishes it as the new `AppConfig.llmService` so the rest of
    /// the app (ChatService, MedicalChatOrchestrator) observes the swap — mirroring what
    /// `AppConfig.switchModel` does, but synchronously awaited end-to-end. Returns the concrete
    /// `LLMService` (not the protocol) so the caller can `unload()` it directly afterward.
    private static func loadModel(_ model: ModelCatalog) async -> LLMService? {
        if let realService = AppConfig.llmService as? LLMService {
            realService.unload()
        }

        guard AppConfig.shouldInitializeRuntime else {
            // Simulator/Mac: no MLX runtime, nothing to load. Leave the mock in place.
            AppConfig.llmService = MockLLMService()
            return nil
        }

        do {
            let modelURL = try await ModelManager.shared.ensureModelReady(modelName: model.repoID)
            let service = LLMService(modelPath: modelURL.path, useMock: false)
            let initialized = await service.initializeModel()
            guard initialized else { return nil }

            AppConfig.llmService = service
            AppConfig.selectedModel = model
            return service
        } catch {
            print("WoundAnalysisService: failed to load \(model.displayName) — \(error)")
            return nil
        }
    }

    /// Drains an LLM token stream into a single string — same pattern as
    /// `MedicalChatOrchestrator.accumulate`.
    private static func accumulate(stream: AsyncStream<String>) async -> String {
        var result = ""
        for await token in stream {
            result += token
        }
        return result
    }
}
