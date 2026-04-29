# Backend Guide

This is the single source of truth for the backend structure in `MobiCureVN`.

## What was removed

These old locations and duplicate structures were removed or consolidated:

- `MobiCureVN/Backend/Service/`
- `MobiCureVN/Backend/Data/`
- `MobiCureVN/Backend/Domain/Entities/`
- `MobiCureVN/Backend/Services/LLM/Adapters/`

## Current naming conventions

Use these names for new backend code:

- `Configs/` for app-wide configuration and dependency injection
- `Services/LLMService/` for the main LLM service implementation
- `Services/LLM/` for model management and LLM infrastructure helpers
- `Store/` for local in-memory or persistence-oriented state
- `Domain/Models/` for data models and value objects
- `Domain/Protocols/` for service contracts
- `Mocks/` for test or preview-only implementations

## Notes for new files

- Keep app code inside `MobiCureVN/` free of documentation files so Xcode does not try to bundle them.
- Put future docs only under `Docs/`.
- Prefer short, intention-revealing names over legacy names like `Engine`, `Entities`, or `Data` when they are not serving a clear purpose.

## Rule of thumb

If a file is part of runtime code, keep it under `MobiCureVN/Backend/`.
If a file is documentation, keep it under `Docs/`.


## Current mock flow

The app is currently wired to the mock backend end-to-end for local testing:

1. `HomeView` creates `ChatView(llmService: AppConfig.llmService)`.
2. `AppConfig.llmService` returns `MockLLMService()`.
3. `ChatView` passes that service into `ChatViewModel`.
4. `ChatViewModel` calls `stream(request:)` on the injected service.
5. `MockLLMService` reads `request.userMessage` and picks a canned response based on simple keyword matching.
6. The mock response is streamed back word-by-word with a small delay, so the UI still looks like a live model.

Important details:

- The preview in `ChatView.swift` also uses `MockLLMService()`, but that only affects SwiftUI previews.
- The actual phone app flow comes from `HomeView -> AppConfig.llmService`.
- There is no MLX/model download path active right now in the runtime backend.

Example behavior:

- If the message contains `infection`, `nhiễm trùng`, or `mủ`, the mock returns the infection-care response.
- If it contains `pain`, `đau`, or `đớn`, the mock returns the pain-care response.
- Otherwise, it returns the general post-op guidance response.