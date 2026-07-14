# MobiCureVN — Performance Branch Summary

> For LLM context: this document describes 13 performance/fix branches that were split from a
> single working-tree change and pushed to GitHub. Each branch is independently applyable to
> `main`. Branch `perf/dev-signing-team` (#15) is local-only and was not pushed.

---

## Why these branches exist

The codebase had a large pile of uncommitted performance work. It was broken into non-overlapping
units so each can be reviewed and merged independently. `branch-split/BRANCHES.md` has the full
breakdown with patch details; this document gives the LLM-readable summary.

---

## Branch overview

### `perf/generation-pipeline` — the big one
**Problem:** output guardrail ran *after* tokens were streamed to the user (safety hole); emergency
detection ran after the input guardrail (people in crisis might be filtered out); no cancellation of
in-flight generation; citations came from a redundant second retrieval with a different query than the
one used for generation.

**Fix:** rework `MedicalChatOrchestrator` + `ChatViewModel` as a coherent unit:
- Emergency detection now runs *first*, before input guardrail.
- LLM output is accumulated in a buffer; `OutputGuardRail` redacts unsafe content *before* the user
  sees any of it.
- Stop / clear / view-switch cancels the generation task all the way down to `LLMService`.
- Sources from the single generation-time retrieval are surfaced via `onSourcesRetrieved`; the
  redundant second retrieval in `finalizeResponse` is removed.

**Files:** `MedicalChatOrchestrator`, `ChatViewModel`, `ChatService`, `MockLLMService`,
`MessageBubble`, `EmergencyDetector`, `LLMService`, `OutputGuardRail`, `GuardRailResult`,
`OutputGuardRailTests`.

---

### `perf/enum-camelcase`
**Problem:** `EmergencySymptomType` cases used snake_case (`difficulty_breathing`), inconsistent
with Swift conventions and breaking pattern-match clarity.

**Fix:** rename all cases to camelCase (`difficultyBreathing`, etc.).

**Files:** `GuardRailResult`, `GuardRailRules`, `EmergencyDetectorTests`, `ModelTests`.

---

### `perf/guardrail-thread-safety`
**Problem:** shared singletons (`GuardRailRules.medicalAnchors`, `QueryEmbedder`, `SQLiteRetriever`)
are read on the generation task while a startup task may still be writing — data race, potential crash.

**Fix:** add a lock on `medicalAnchors`, a `predictionLock` on `QueryEmbedder`, and open SQLite
with `SQLITE_OPEN_FULLMUTEX`.

**Files:** `GuardRailRules`, `QueryEmbedder`, `SQLiteRetriever`.

---

### `perf/rag-retrieval`
**Problem:** on-device CoreML embedding dominates per-query latency (hundreds of ms) and was run
on *every* query, even when FTS5 already returned enough results. FTS base clause was AND-only,
causing zero matches on natural patient phrasing.

**Fix:** run vector search only when FTS returns fewer than `topK` results ("thin"). Change FTS
token join from `AND` to `OR` (BM25 scoring + RRF fusion handle noise from over-retrieval).

**Files:** `SQLiteRetriever`.

---

### `perf/regex-precompile-pii`
**Problem:** `NSRegularExpression` objects for PII masking were rebuilt inside the call on every
query — expensive for hot paths.

**Fix:** compile the regexes once as static properties.

**Files:** `InputGuardRail`.

---

### `perf/model-manager-memory`
**Problem:** model archive validation loaded multi-GB zip files entirely into RAM for SHA-256 and
magic-byte checks. No pre-download disk-space guard.

**Fix:** stream SHA-256 in 1 MB chunks, read only 200 bytes for the zip magic-byte sniff, check
available disk space before starting a download.

**Files:** `ModelManager`.

---

### `perf/chat-history-repo`
**Problem:** `loadHistory()` fetched all `ChatRecord` rows from SwiftData then filtered in-memory
by `conversationId`. Unused `clear()` API. Citation sources were not persisted — lost on app restart.

**Fix:** push the per-conversation filter into SwiftData via `#Predicate`; remove unused API;
add `sourcesData: Data?` to `ChatRecord` and make `MedicalSource` `Codable` so citations survive
app restarts.

**Files:** `ChatHistoryRepository`, `InMemoryChatHistoryRepository`, `SwiftDataChatHistoryRepository`,
`ChatRecord`, `MedicalSource`.

> Pairs with `perf/generation-pipeline` for the full citation persistence feature.

---

### `perf/startup-warmup`
**Problem:** `AppConfig.retriever` (SQLite open + CoreML embedder load) was initialized lazily on
`@MainActor` inside `ChatViewModel.init` — blocking the main thread on first use.

**Fix:** warm the retriever on a utility-priority `Task` in `MobiCureVNApp` at launch, off the main
thread.

**Files:** `MobiCureVNApp`.

---

### `perf/anchor-count`
**Problem:** `MedicalAnchorLoader` parsed up to 300 medical anchors; in practice only ~50 are ever
consulted, making the parse ~5× slower than necessary.

**Fix:** lower `maxAnchors` from 300 to 60.

**Files:** `MedicalAnchorLoader`.

---

### `perf/chatgrouper-future-dates`
**Problem:** `ChatGrouper` used an upper bound of `Date()` for the "Today" group. Items with a
timestamp even slightly in the future (clock skew, simulator time drift) disappeared from the list.

**Fix:** remove the upper bound on "Today" so future-dated items still appear in that group.

**Files:** `ChatGrouper`.

---

### `perf/dead-code-cleanup`
**Problem:** several files and types were no longer referenced anywhere in the codebase, adding
noise and compile time.

**Deleted:** `LLMResponse`, `ConversationMemory`, `ToolExecutor`, `ChatResponse`,
`QueryRewriteService`; a redundant `print` in `AppConfig`; the unused `static orchestrator`
property; a filename typo in `CitationCard`'s header comment.

**Files:** multiple; all deletes, no logic changes.

---

### `perf/build-without-secrets`
**Problem:** `Secrets.swift` is gitignored (contains real Kaggle credentials), so a fresh clone
failed to build — `Secrets.kaggleUsername` / `Secrets.kaggleApiKey` didn't resolve.

**Fix:** add placeholder string literals in `AppConfig` so the project builds out of the box.
Real credentials must be restored (via `Secrets.swift` or env vars) before using the Kaggle loader.

**Files:** `AppConfig`.

---

### `perf/dev-signing-team` ⚠️ local only
A `DEVELOPMENT_TEAM` ID change in `project.pbxproj` for a specific developer's machine. Not
pushed. Listed for completeness.

---

## What remains after merging all branches

The following items from `bugCheck.md` are **not** addressed by any of these branches and still
need work:

| Item | Location | Status |
|------|----------|--------|
| Chat template wrong for Qwen/Llama | `LLMService.swift:138` | open |
| No generation timeout | `LLMService.swift:85` | open |
| UI rebuild per token (`rebuildSections`) | `ChatViewModel.swift:166` | open |
| `candidateLimit` no-op `max()` | `SQLiteRetriever.swift:50` | open |
| Word-count "token" budget | `MedicalChatOrchestrator.swift:206` | open |
| Patient profile not injected into prompts | `MedicalChatOrchestrator.swift` | open |
| CitationCard still uses mock data (wiring) | `CitationCard.swift` | open — sources are now persisted, wiring still needed |
| Translation cold-start / medical term map | `TranslationService.swift`, `QueryRefiner` | open |
| Knowledge base < 1,500 chunks | `vectorstore.db` | open |
| Generation eval (answer_similarity = 0) | `Pipeline/eval/` | open |
| Vietnamese guardrail | `OutputGuardRail` | done by another team member — verify |
