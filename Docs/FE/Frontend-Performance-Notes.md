# Frontend performance — findings to action

_Audit 2026-09-12. Static analysis only; nothing here has been measured with Instruments._

All four findings share one trigger: **`rebuildSections()` runs ~20 times a second while a
reply streams** (`ChatViewModel.swift:174`, and the comment at `:79` already says so). Every
frame re-runs the work below, **while the on-device model is generating** — so this is not
just UI smoothness, it is CPU taken away from the LLM and therefore latency.

Fix C1 first: it is the multiplier on the other three.

---

## C1 — `rebuildSections()` rebuilds everything, 20×/sec

`ChatViewModel.swift:174-176`

```swift
private func rebuildSections(now: Date = Date()) {
    self.sections = ChatGrouper.group(self.itemsAsChatItems(), now: now)
}
```

Per frame:

- `itemsAsChatItems()` (`:156`) allocates a fresh `ChatItem` for **every message in the
  conversation**, copying `sources`, `imageData` and `profileUpdateProposals` each time.
- `ChatGrouper.group()` (`App/Backend/Domain/Models/ChatGrouper.swift:10`) calls
  `calendar.startOfDay` and `calendar.date(byAdding:)` **three times**, then walks every item
  into five buckets. `Calendar` arithmetic is expensive,
  and the day boundaries it computes change **once a day**.

**Suggested fix**

1. Cache the four day boundaries (today, yesterday, 7 and 30 days back); recompute only when the day changes. They are pure
   functions of `startOfDay(now)`.
2. While streaming, only the last message changes. Either update that one section in place,
   or throttle `rebuildSections()` to the existing `previewInterval` cadence rather than
   calling it per token event.
3. Consider making `ChatSection`/`ChatItem` `Equatable` so SwiftUI can skip untouched rows.

**Do not** change `messageIDs` identity handling — the comment at `:77-82` explains why the
ids are kept stable, and regressing that would make SwiftUI tear down the whole list.

## C2 — Markdown re-parsed on every body evaluation

`MessageBubble.swift:122`

```swift
if let attributed = try? AttributedString(markdown: content, options: ...) {
```

During streaming this parses a **growing** string ~20×/sec. Cost rises with answer length,
so it is worst exactly when the answer is longest.

**Suggested fix:** parse only for the final text. While a message is the streaming one
(`viewModel.streamingMessageID == message.id`), render `Text(content)` plain — the draft is
display-only and is replaced by the validated `.final` anyway. Optionally memoise the parsed
`AttributedString` per message id.

## C3 — Images re-decoded on every body evaluation

`MessageBubble.swift:134`

```swift
let images = message.imageData.compactMap { UIImage(data: $0) }
```

`UIImage(data:)` decodes the JPEG each time the body runs. With the list re-rendering 20×/sec,
every visible bubble that has a photo re-decodes at that rate.

**Suggested fix:** decode once and cache by message id (a small `NSCache<NSUUID, UIImage>` or
a decoded value stored alongside the message). Also consider `UIImage.preparingForDisplay()`
off the main thread so the decode does not land in a view body at all.

## C4 — Formatter allocated per row, per render

`ChatWorkspaceView.swift:1127`

```swift
private func relativeDate(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    ...
}
```

Constructing a `DateFormatter`/`RelativeDateTimeFormatter` is one of the classic iOS cost
traps, and this runs once per conversation row per render.

**Suggested fix:** hoist to a `static let`, keyed by locale if `appLanguage` can change at
runtime.

Same pattern, lower traffic (not in the streaming path, fix when convenient):

- `ProfileView.swift:522`

---

## Checked and found fine — do not spend time here

- `ForEach` uses stable identities throughout; `messageIDs` is deliberately kept in step.
- No `Timer` / polling anywhere in the app.
- `localized(for:)` (`AppLanguage.swift:22`) constructs a `Bundle` on every call, which looks
  alarming — but there are only 21 call sites and they are all ViewModel error strings, not
  view-body labels. Not a hot path. Cache it if you are touching the file anyway, otherwise
  leave it.
- Image attachment handling (`UIImage+Attachment.swift`) already downscales and re-encodes
  correctly, and the comment explains why it always redraws (orientation baking). Leave it.

---

## Related, but backend — not this list

`ChatViewModel:299` and `:404` call `refreshConversationHistory()` **twice per turn**, and
each call fetches every `ChatRecord` row in the database including image blobs
(`SwiftDataChatHistoryRepository.swift:34`, `loadConversations()`). That is the single most expensive thing the chat
screen triggers, but the fix belongs in the Store layer, and is tracked separately on the
backend side. Coordinate before changing the call sites.

---

## How to verify

None of this is measured. Before and after any change:

- Instruments → **Time Profiler** + the **SwiftUI** instrument, with a reply streaming.
- Watch `rebuildSections`, `ChatGrouper.group`, `AttributedString.init(markdown:)` and
  `UIImage(data:)` in the sample tree.
- The end-to-end number that matters is in `MobiCureVNTests/LatencyBenchmarkTests.swift`
  (see `Docs/BE/Latency-Benchmark.md`) — UI cost shows up there as slower decode, because
  the main thread competes with the model.
