# Backend Guide

This is the single source of truth for the backend structure in `MobiCureVN`.

## What was removed

These old locations and duplicate structures were removed or consolidated:

- `MobiCureVN/Backend/Service/`
- `MobiCureVN/Backend/Data/`
- `MobiCureVN/Backend/Domain/Entities/`
- `MobiCureVN/Backend/Services/LLM/Adapters/`
- Nested backend README files that were scattered across the source tree

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
