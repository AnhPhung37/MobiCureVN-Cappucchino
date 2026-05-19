# Profile and Citation Design — MobiCureVN

Last updated: 2026-05-19

## Overview

This document describes the in-app data models and the citation (RAG) pipeline used for AI replies. It summarizes existing implementations, data flow, persistence decisions, UI presentation, and recommended improvements.

## Models

### PatientProfile
- Location: `App/Backend/Domain/Models/PatientProfile.swift`
- Purpose: represent a patient's profile displayed in the Profile UI.
- Fields:
  - `id: UUID`
  - `name: String`
  - `age: Int`
  - `gender: String`
  - `diagnosis: String`
  - `procedure: String`
  - `recoveryStage: String`
  - `reportSummary: String`
  - `careNotes: [String]`
  - `warningSigns: [String]`
  - `sourceName: String` — data source display name
  - `lastUpdated: Date`
- Repository pattern: `PatientProfileRepository` with `MockPatientProfileRepository` used in `AppConfig` for now.

### Session / Conversation
- Conversation summary: `ChatConversationSummary` (`id, title, preview, lastMessageDate, messageCount`) — located at `App/Backend/Domain/Models/ChatConversationSummary.swift`.
- Persistent record (SwiftData): `ChatRecord` — located at `App/Frontend/VVM/Chat/ChatRecord.swift`.
  - Fields: `id: UUID (unique), conversationId: UUID?, role: String, content: String, date: Date`.
  - Stored via `SwiftDataChatHistoryRepository` which maps DB rows → `ChatItem` and groups by `conversationId`.
- In-memory representation when loading: `ChatItem` (adds `sources: [MedicalSource]` for domain usage).

### Message
- Runtime message: `ChatMessage` — `role: String`, `content: String`, `sources: [MedicalSource]`.
  - Used throughout UI and LLM pipeline.
  - Location: `App/Backend/Domain/Models/ChatMessage.swift`.
- Persisted message: `ChatRecord` as above — note that `ChatRecord` currently does NOT include `sources`.

## MedicalSource (Citation model)
- Location: `App/Backend/Domain/Models/MedicalSource.swift`.
- Fields:
  - `id: String` — document id
  - `title: String` — section or title
  - `excerpt: String` — short excerpt shown in UI
  - `page: Int` — page number (may be 0 if unknown)
  - `documentName: String` — human-readable name (sourceOrg + docType)
- `MedicalSource` conforms to `Identifiable` and `Sendable` for UI use.

## Citation / RAG Pipeline

Flow (high-level):
1. User sends query via UI (`ChatViewModel.sendMessage()`).
2. `MedicalChatOrchestrator` orchestrates: input guardrail → emergency detection → RAG retrieval → prompt enrichment → stream LLM tokens → output guardrail.
3. `RAGService` calls `SQLiteRetriever.retrieve()` (bundled `vectorstore.db`) to fetch `ContextChunk`s and deduped `MedicalSource`s.
   - Retriever uses FTS5 (`chunks_fts`) when available, otherwise a fallback LIKE search.
   - Confidence score is computed in `SQLiteRetriever.calculateConfidence(rows:)`.
4. `MedicalChatOrchestrator.buildEnrichedPrompt(...)` inserts the retrieved chunks and a formatted `Sources:` block into the system prompt and sets a requirement: `ALWAYS cite your sources`.
5. `LLMService` builds final prompt including conversation history and streams tokens back.
6. After streaming completes, `ChatViewModel` runs a secondary retrieval (`citationRetriever.retrieve(...)`) to collect `MedicalSource`s and attaches them to the final assistant `ChatMessage` (in-memory) so the UI displays citations.

Key implementation files:
- Retriever: `App/Backend/Services/RAG/SQLiteRetriever.swift`
- RAG orchestration: `App/Backend/Services/RAG/Retriever.swift` (RAGService)
- Orchestrator: `App/Backend/Services/GuardRail/MedicalChatOrchestrator.swift`
- LLM interface: `App/Backend/Services/LLMService/LLMService.swift`
- Chat VM: `App/Frontend/VVM/Chat/ChatViewModel.swift`
- UI: `App/Frontend/VVM/Chat/CitattionCard.swift`

## Current behaviors & notable gaps
- The system prompt explicitly instructs the LLM to cite sources and includes a formatted sources list and confidence score.
- `SQLiteRetriever.dedupedSources(...)` deduplicates by `docID` and creates `MedicalSource` objects used for presentation.
- After the assistant's reply finishes streaming, the `ChatViewModel` runs `citationRetriever.retrieve(...)` separately and attaches the resulting `MedicalSource`s to the assistant message before persisting.

Persistence gap (important):
- `ChatRecord` (SwiftData model) does not contain a `sources` field. When messages are saved via `SwiftDataChatHistoryRepository`, `sources` are not stored. Consequently, citations are only available in-memory immediately after generation, not when re-loading history later.

Confidence & credibility:
- Retriever computes a confidence score (0–1) from chunk relevance and a credibility tier. Tier-1 documents get a small boost.
- Confidence is embedded in the system prompt to guide the model and surfaced in logs.

## UI
- Chat UI displays messages as `ChatMessage` objects (role, content, sources).
- `CitationsView` / `CitationCard` show `MedicalSource` entries with title, page, excerpt and document name.

## Recommended improvements
1. Persist `sources` with messages
   - Add `sources: Data` (or a separate relation) to `ChatRecord` and encode `[MedicalSource]` using `Codable`/JSON or a to-many relation in SwiftData.
   - Update `SwiftDataChatHistoryRepository.append(_:)` to write `sources` and `loadHistory(...)` to read them back into `ChatItem`.
   - This preserves citations across app restarts and when browsing past conversations.

2. Store more robust document metadata
   - Ensure `vectorstore.db` includes persistent `page` and canonical `documentName` fields, and that `MedicalSource` `page` is populated.

3. Surface confidence in UI (optional)
   - Show confidence percentage alongside sources to help users gauge reliability.

4. Improve citation formatting in prompts
   - Use short numeric reference markers (e.g. [1], [2]) in the system prompt and ask the LLM to inline these markers in answers so UI can link inline citations to `MedicalSource` cards.

5. Consider storing a small `LLMResponse` record
   - Save response metadata such as `tokensUsed`, `modelVersion`, and `citations` for analytics and auditing.

## Suggested schema change example (SwiftData)
```swift
@Model
final class ChatRecord {
    @Attribute(.unique) var id: UUID
    var conversationId: UUID?
    var role: String
    var content: String
    var date: Date
    var sourcesJSON: String? // new: JSON-encoded [MedicalSource]

    init(...) { ... }
}
```
- Repository: encode/decode `MedicalSource` via `JSONEncoder`/`JSONDecoder` when writing/reading.

## Where to start implementing persistence for sources
1. Update `ChatRecord` model.
2. Update `SwiftDataChatHistoryRepository.append(_:)` to include `sources` when creating `ChatRecord`.
3. Update `loadHistory(...)` implementations to decode `sourcesJSON` into `[MedicalSource]` and include them in returned `ChatItem`.
4. Add a migration strategy or clear existing DB if schema changes are incompatible.



## Diagram

Below is a small Mermaid diagram that visualises the RAG → LLM → Citation pipeline used by the app.

```mermaid
flowchart LR
   U[User]
   U -->|sends query| VM[ChatViewModel]
   VM -->|orchestrate| O[MedicalChatOrchestrator]
   O --> IG[Input GuardRail]
   O --> ED[Emergency Detector]
   O --> RS[RAGService]
   RS --> SR[SQLiteRetriever]
   SR --> VDB[(vectorstore.db)]
   RS --> O
   O --> LLM[LLMService]
   LLM -->|stream tokens| VM
   VM -->|post-retrieve for citations| SR
   SR --> MS[MedicalSource[]]
   VM -->|attach sources| UI[CitationsView / CitationCard]

   classDef external fill:#f9f,stroke:#333,stroke-width:1px;
   class VDB external;
```




