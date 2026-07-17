# On-Device LLM Memory Management (OOM Fix)

This documents the fix for `bugCheck.md` §7.1 — the app being killed by iOS under memory pressure during on-device LLM chat. It covers what was wrong, what changed, why, and what's still worth improving as the project scales.

Related files:
- `App/Backend/Services/LLMService/LLMService.swift`
- `App/Backend/Configs/AppConfig.swift`
- `App/Backend/Configs/ModelCatalog.swift`
- `App/Frontend/App/MobiCureVNApp.swift`

## 1. The problem

The app runs a 3B–7B parameter LLM (Qwen2.5, via MLX Swift) entirely on-device. That's already a lot of fixed memory (model weights). On top of that, three *unbounded* sources of variable memory could each independently push the app over iOS's memory budget and get it killed by [jetsam](https://developer.apple.com/documentation/xcode/identifying-high-memory-use-with-jetsam-event-reports) (iOS's out-of-memory process killer — unlike a normal crash, there's no exception or stack trace, the app just disappears):

1. **Unbounded token stream buffer.** Token generation used `AsyncStream(bufferingPolicy: .unbounded)`. If whatever was consuming the stream (the chat UI) fell behind the producer — a slow SwiftUI re-render, the app briefly backgrounded, a long response — every generated token queued up in memory with no ceiling.
2. **Unbounded MLX Metal cache.** MLX doesn't free GPU buffers the instant they're done being used; it pools/recycles them for the next token, for performance. Without an explicit cap, this pool is allowed to grow up to whatever Metal's `recommendedMaxWorkingSetSize()` permits — which competes directly with the OS-level memory budget for the whole app instead of leaving headroom for everything else (UI, RAG/SQLite, translation, etc).
3. **No way to give memory back under pressure.** Once the model was loaded, there was no code path that reacted to a system memory warning. iOS can tell an app "you're using too much memory, free some now or you may be killed" — the app simply had nothing listening for that signal.

Each of these was already identified (not yet fixed) in `bugCheck.md` §7.1 before this change.

## 2. The fix

Three changes, all small and localized:

### 2.1 Cap the stream buffer

`LLMService.swift`, both `generate(...)` overloads (the MLX path and the placeholder/mock path):

```swift
// before
AsyncStream<String>(bufferingPolicy: .unbounded) { continuation in ... }

// after
AsyncStream<String>(bufferingPolicy: .bufferingNewest(512)) { continuation in ... }
```

If the consumer falls behind, the **oldest** buffered tokens are dropped instead of accumulating forever. This is safe specifically because the UI has almost certainly already rendered those older tokens by the time they'd be evicted — nothing the user sees is lost, only the internal replay buffer (which exists for backpressure handling) is bounded.

### 2.2 Cap the MLX Metal buffer cache

`LLMService.swift`, inside `initializeModel()`, right after a successful model load:

```swift
MLX.Memory.cacheLimit = 512 * 1024 * 1024 // 512 MB
```

This bounds how large MLX's GPU buffer-reuse pool is allowed to grow during generation, so a long response or a long multi-turn conversation can't let it balloon unchecked.

> **API note:** the commonly-referenced way to do this is `MLX.GPU.set(cacheLimit:)`. That method is **deprecated** in the version of mlx-swift this project is pinned to (0.31.3, via `Package.resolved` → `mlx-swift-lm` 3.31.3). `MLX.Memory.cacheLimit` is the current, non-deprecated equivalent. This was confirmed by reading the vendored package source directly (`mlx-swift/Source/MLX/Memory.swift` and `GPU+Metal.swift`, resolved locally under Xcode's `DerivedData/.../SourcePackages/checkouts/`) rather than assumed — the deprecated API would still compile (with a warning) but is the wrong one to reach for in new code.

### 2.3 React to memory-pressure warnings

`LLMService.swift` gained a new method:

```swift
func unload() {
    modelContainer = nil
    mlxInitialized = false
    MLX.Memory.clearCache()
}
```

`AppConfig.swift` gained `observeMemoryWarnings()`, called once from `MobiCureVNApp.init()`:

```swift
memoryWarningObserver = NotificationCenter.default.addObserver(
    forName: UIApplication.didReceiveMemoryWarningNotification,
    object: nil,
    queue: .main
) { _ in
    if let realService = llmService as? LLMService {
        realService.unload()
    }
}
```

When iOS signals memory pressure, the loaded model is released and MLX's cache is force-cleared immediately (`clearCache()` matters here because the cache limit from §2.2 only takes effect lazily, on the *next* deallocation — under active pressure we want it gone *now*, not eventually). The next chat message after an `unload()` falls back to placeholder/mock text until `initializeModel()` reloads the model on a later call. This is a deliberate trade-off: a temporarily degraded response is much better than the app being killed mid-conversation and losing all unsaved state.

> **What `unload()` does *not* delete — conversation history and user context are safe.**
> - `MLX.Memory.clearCache()` only frees MLX's internal pool of recycled GPU scratch buffers (allocator-level temp memory, like `malloc_trim`) — it has no concept of "conversation" and doesn't touch model weights or chat state.
> - `modelContainer = nil` releases the loaded model *weights* — the only thing actually freed besides the Metal cache.
> - The chat conversation itself (`[ChatMessage]` history) is never stored inside `LLMService` or MLX at all — it lives in `ChatViewModel` / `ChatHistoryRepository` (SwiftData/SQLite), completely outside this code path, and is untouched by `unload()`.
> - There is also no persistent "attention window" / KV cache living across turns to lose in the first place (see §3) — each `generate()` call builds the full prompt fresh from the externally-held history and constructs its own scratch KV state for that single call, discarding it when the call ends.
>
> So the actual cost of `unload()` is purely a **reload delay** (the next message pays the multi-second model-load cost again) — not lost context. The app will still "remember" everything said so far; it just answers slower on the next turn.

## 3. What was investigated but did *not* need changing

- **Model file downloads** (`ModelManager.swift`, `downloadCommunityRepository`): the original bug report assumed files were buffered fully in memory before being written to disk. Re-reading the code showed it already uses `URLSession.download(for:)`, which streams each file straight to a temp location on disk and then moves it into place — there was no in-memory buffering to fix.
- **"Clear the KV cache" on memory warning**: the original plan (and the general folk-knowledge around LLM inference) assumes there's a persistent KV cache object on the loaded model that can be cleared independently of unloading the whole model. Inspecting the `mlx-swift-lm` package source (`ModelContainer.swift`) showed no such persistent, container-level object — the KV cache is scoped to a single `generate()` call and doesn't survive between turns. So "clear the KV cache" doesn't correspond to any real API here; releasing the whole `ModelContainer` via `unload()` is the actual lever available.

## 4. Architecture side-effect: actor isolation

This project's Xcode target sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (a newer Xcode default for new projects). That means **every type without explicit isolation is implicitly pinned to the main actor** — not just classes that look like they need it.

This surfaced two build errors while making the above changes, both fixed by adding an explicit `nonisolated`:

- **`LLMService`** runs generation work inside `Task.detached`, deliberately off the main actor (so a long generation doesn't block the UI thread). Under Swift 6's concurrency checker, that detached work touching `self.modelContainer` / `self.mlxInitialized` on an implicitly-`@MainActor` class is illegal cross-actor access. Fixed by declaring `nonisolated final class LLMService`.
- **`ModelCatalog`** is a plain data enum with `static let default: ModelCatalog = .qwen2_5_3B`, used as a default parameter value elsewhere (`model: ModelCatalog = .default`). Default-argument expressions are evaluated in a `nonisolated` context by the Swift language itself — so a static property that's implicitly `@MainActor` (because the enum has no explicit isolation, under this project's default) can't be referenced there. Fixed by declaring `nonisolated enum ModelCatalog`.

**Takeaway for future code in this target:** don't rely on isolation inference. Any plain data type, or any class/actor whose work is meant to run off the main thread, needs an explicit `nonisolated` (or `@MainActor` if it genuinely belongs on the main actor) — the project-wide default silently pins everything else to the main actor, and the failure mode is a compiler error/warning that can look unrelated to whatever you actually changed.

## 5. Verification

Verified by running a full `xcodebuild` for iOS (device destination, not simulator — MLX requires real Metal GPU hardware and does not run in the iOS Simulator; see `mlx-swift`'s own "Developing for iOS" notes). Build succeeded with zero errors/warnings on the touched files.

Not yet verified: actual on-device memory profiling (Instruments → Allocations + Metal System Trace) during a long real conversation on a low-RAM device. That's the natural next validation step — the fix addresses the three identified unbounded-growth sources, but the *right* numbers (512 MB cache, 512-token buffer) are reasonable defaults, not measured ones. See §6.

## 6. Future optimization ideas (for when this scales up)

- **Scale the cache limit to device RAM instead of a fixed 512 MB constant.** Read `ProcessInfo.processInfo.physicalMemory` at startup and pick a cache limit proportional to it (e.g. ~256 MB on a 3–4 GB device, 768 MB–1 GB on 8 GB+ devices). Right now the same constant is used everywhere, which is conservative-to-the-point-of-wasteful on capable devices and just barely safe (or not) on constrained ones.
- **Tune the 512-token stream buffer size with real data.** It's currently a reasonable round number, not a measured one. Profiling the actual steady-state lag between token production and UI consumption during a long conversation would give a number to size the buffer to (plus margin) instead of a guess.
- **Partial/tiered unload instead of always fully unloading.** `unload()` currently always drops the entire `ModelContainer`, so the *next* message after any memory warning pays the full model-load cost again (a multi-second stall the user will notice). A future version could distinguish lighter pressure (just force-clear the Metal cache, keep the model resident) from severe/repeated pressure (fully unload) — useful if iOS ever exposes warning severity, or by tracking how many warnings arrive in a short window.
- **Surface the unload event in the UI.** `AppConfig` already has a download-progress notification mechanism (`llmDownloadProgressDidChange`) that the UI subscribes to. Extending that pattern to show "conversation paused to free memory, reloading…" when `unload()` fires would prevent a memory-triggered fallback to placeholder text from looking like an unexplained bug to the user.
- **Add automated regression coverage for this.** There's no CI in the project yet (`bugCheck.md` §7.5) and no test that exercises a long multi-turn conversation under constrained memory. Once CI exists, a scripted UI test running N turns on a low-RAM simulator/device target and asserting no crash/jetsam-kill would catch regressions here automatically instead of relying on manual Instruments runs before each release.
- **Treat quantization/model size as the real long-term lever.** Buffer and cache caps only bound the *variable* memory cost of inference. The *fixed* cost — holding a 3B–7B parameter model resident in RAM, even 4-bit quantized — is the dominant term on low-RAM devices and isn't touched by this fix. If OOM reports continue after this change, the next place to look is defaulting to a smaller model in `ModelCatalog` (it already includes a 1B Gemma variant) rather than further tuning buffers.
