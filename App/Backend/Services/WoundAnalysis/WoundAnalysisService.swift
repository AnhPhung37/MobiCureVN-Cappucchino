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

    /// The VLM is asked to emit exactly these keys, one `KEY: value` line each, so
    /// `WoundFindingsParser` can map the output to `WoundLogEntry` fields deterministically.
    /// The keys must stay in sync with `WoundFindingsParser.Field`.
    private static let findingsSystemPrompt = """
    You are a visual observation tool. Describe ONLY what is visible in the photo.

    Output EXACTLY these lines, one per line, in this order, using this exact "KEY: value"
    format. Do not add, remove, reorder, or rename any key. Do not add any other text.

    STOMA_COLOR: <color of the stoma tissue, e.g. pink, red, pale, dark>
    STOMA_SIZE_CHANGE: <any change in size/protrusion vs. normal, or "unchanged">
    SURROUNDING_SKIN: <color/texture changes of skin around the site>
    OUTPUT_APPEARANCE: <appearance of any output/discharge: color, consistency>
    BAG_SEAL: <condition of the bag/appliance seal if visible>
    SWELLING_OR_PROTRUSION: <location and extent of swelling or protrusion>
    OTHER: <any other visible finding>

    If a given line is not visible or not applicable, write "Not visible" as its value — do
    not guess.

    Do NOT diagnose. Do NOT assess infection risk. Do NOT recommend treatment. Only describe
    what is visually present in the image.
    """

    /// Result of a wound analysis: the raw findings text (used to drive the chat pipeline) and
    /// the structured log entry that was persisted (nil if analysis produced no findings, or if
    /// the entry could not be saved).
    struct AnalysisResult {
        let findings: String
        let entry: WoundLogEntry?
    }

    /// Runs the VLM over the attached photo(s), returns its structured findings text, and
    /// persists a structured `WoundLogEntry` to `repository`.
    ///
    /// Sequencing: when the resident model is itself vision-capable there is no swap at all —
    /// the photo goes straight to it. Only a text-only resident model triggers the swap below.
    ///
    /// Swap path: unloads whatever model is currently resident in `AppConfig.llmService`,
    /// loads the wound VLM and awaits it, runs inference, unloads the VLM, then reloads
    /// `AppConfig.selectedModel` (the user's chosen text model) and awaits that too before
    /// returning — so by the time this call completes, `AppConfig.llmService` is back to a
    /// ready, resident text model and the caller can safely run a normal `processQuery`.
    ///
    /// The findings text is parsed into structured fields by `WoundFindingsParser` (deterministic,
    /// no extra model call) and the first attached photo is saved to disk via `WoundPhotoStore`,
    /// referenced by the persisted entry. Persistence failures are non-fatal: the findings are
    /// still returned so the chat turn proceeds, and `entry` is left nil.
    static func analyzeWound(
        images: [Data],
        patientID: UUID = AppConfig.localPatientID,
        repository: WoundLogRepository = AppConfig.woundLogRepository
    ) async -> AnalysisResult {
        guard !images.isEmpty else { return AnalysisResult(findings: "", entry: nil) }

        let request = LLMRequest(
            systemPrompt: Self.findingsSystemPrompt,
            userMessage: "Describe the visual findings in this photo.",
            images: images,
            // The KEY: value line set is a contract WoundFindingsParser reads positionally, so
            // decode close to greedily — a renamed or reordered key yields empty fields.
            options: .structuredDescription
        )

        // Fast path: the resident model can already see, so there is nothing to swap. The
        // catalog default (Qwen 3.5 4B) is vision-capable, which makes this the common case —
        // and the swap it avoids is not cheap: unload, read a multi-GB model off disk, init
        // Metal, generate, unload, then read the text model back in. `isVisionModel` is read
        // from the loaded weights' own config.json rather than from the catalog, so this
        // follows what is actually resident even if the catalog metadata drifts.
        if let resident = AppConfig.llmService as? LLMService, resident.isVisionModel {
            let findings = await accumulate(stream: resident.stream(request: request))
            return await finish(
                findings: findings,
                images: images,
                modelUsed: AppConfig.selectedModel.repoID,
                patientID: patientID,
                repository: repository
            )
        }

        // Slow path: a text-only model is resident. Borrow the VLM, then put the user's chosen
        // text model back so the caller can run a normal chat turn straight afterwards.
        let previousModel = AppConfig.selectedModel

        guard let vlmService = await loadModel(Self.woundVLM) else {
            // Download/load failed — restore the previous text model before giving up so the
            // app isn't left with no resident model.
            _ = await loadModel(previousModel)
            return AnalysisResult(findings: "", entry: nil)
        }

        let request = LLMRequest(
            systemPrompt: Self.findingsSystemPrompt,
            userMessage: "Describe the visual findings in this photo.",
            images: images,
            // The KEY: value line set is a contract WoundFindingsParser reads positionally, so
            // decode close to greedily — a renamed or reordered key yields empty fields.
            options: .structuredDescription
        )
        let findings = await accumulate(stream: vlmService.stream(request: request))
        vlmService.unload()

        _ = await loadModel(previousModel)

        return await finish(
            findings: findings,
            images: images,
            modelUsed: Self.woundVLM.repoID,
            patientID: patientID,
            repository: repository
        )
    }

    /// Shared tail of both paths above: bail out on empty findings, otherwise persist and
    /// return. `modelUsed` is recorded on the entry, so it must name the model that actually
    /// produced `findings` — which is no longer always `woundVLM`.
    private static func finish(
        findings: String,
        images: [Data],
        modelUsed: String,
        patientID: UUID,
        repository: WoundLogRepository
    ) async -> AnalysisResult {
        guard !findings.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return AnalysisResult(findings: findings, entry: nil)
        }

        let entry = await persistEntry(
            findings: findings,
            photo: images[0],
            modelUsed: modelUsed,
            patientID: patientID,
            repository: repository
        )
        return AnalysisResult(findings: findings, entry: entry)
    }

    /// Parses `findings`, saves `photo` to disk, and appends a `WoundLogEntry` to `repository`.
    /// Returns the appended entry, or nil if the photo couldn't be written or the append failed
    /// (in which case any already-written photo file is cleaned up so no orphan file is left).
    private static func persistEntry(
        findings: String,
        photo: Data,
        modelUsed: String,
        patientID: UUID,
        repository: WoundLogRepository
    ) async -> WoundLogEntry? {
        let parsed = WoundFindingsParser.parse(findings)
        let entryID = UUID()

        let imageURL: URL
        do {
            imageURL = try WoundPhotoStore.save(jpegData: photo, id: entryID)
        } catch {
            print("WoundAnalysisService: failed to save wound photo — \(error)")
            return nil
        }

        let entry = WoundLogEntry(
            id: entryID,
            patientID: patientID,
            imageReference: imageURL,
            stomaColor: parsed.stomaColor,
            stomaSizeChange: parsed.stomaSizeChange,
            surroundingSkin: parsed.surroundingSkin,
            outputAppearance: parsed.outputAppearance,
            bagSeal: parsed.bagSeal,
            swellingOrProtrusion: parsed.swellingOrProtrusion,
            otherObservations: parsed.otherObservations,
            rawDescription: findings,
            flaggedForReview: parsed.flaggedForReview,
            modelUsed: modelUsed
        )

        do {
            try await repository.append(entry)
            return entry
        } catch {
            print("WoundAnalysisService: failed to persist wound log entry — \(error)")
            WoundPhotoStore.delete(at: imageURL)
            return nil
        }
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
