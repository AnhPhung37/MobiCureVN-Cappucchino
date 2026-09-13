# Privacy / Locality Audit — success criterion #1

> "100% of data processing must occur locally; zero calls to external commercial LLM APIs."

This is the project's strongest claim. It was also, until now, the least evidenced —
asserted in prose, never demonstrated. This document is the evidence procedure.

Run it: `Tools/privacy_audit.sh` (committed output: `Docs/audits/privacy-audit.txt`).

---

## What the static scan checks

| § | Check | Current result |
|---|---|---|
| 1 | Commercial LLM inference endpoints (OpenAI, Anthropic, Gemini, Bedrock, …) | **PASS — zero** |
| 2 | Every hardcoded `http(s)` URL, classified by whether a request is built from it | 2 egress hosts, both declared |
| 3 | `URLSession` / socket / `WKWebView` usage | model download + anchor dataset only |
| 4 | Analytics / telemetry / crash SDKs | **PASS — zero** |
| 5 | Patient-data persistence, file protection, iCloud sync | local-only, `.completeUnlessOpen` |
| 6 | Entitlements / ATS exceptions | no arbitrary-loads exception |
| 7 | Speech recognition forced on-device (`requiresOnDeviceRecognition = true`) | on-device only |

§1, §4, §5 and §7 scan code and configuration only — Swift and Objective-C sources, plists,
entitlements, xcconfig and `project.pbxproj` — never bundled data: the query embedder's
`vocab.txt` contains ordinary words such as "amplitude", which is not an analytics SDK.

The scan distinguishes three kinds of URL, because lumping them together is how a
privacy claim becomes untrue in either direction:

- **comment-only** — a documentation link, not an egress path;
- **string literal** — text in a user-facing error message, no request constructed;
- **reached from code** — an actual request. Only these count.

## The exact claim you can make

> Inference, retrieval, speech recognition, translation, guardrails and storage all execute
> on-device. No patient text, voice, wound photo, or profile field is transmitted anywhere, at
> any time.
> The only network egress is asset download: open-weight model files from Hugging Face.

Do **not** say "the app never touches the network" — it does, and one screenshot of
`ModelManager.swift` would end that claim. The defensible statement is about *patient
data* and *inference*, both of which are genuinely local.

---

## Open finding — resolve before presenting

**`MedicalAnchorLoader` performs a runtime Kaggle download on first launch.**

- `App/Backend/Services/GuardRail/MedicalAnchorLoader.swift:99-107` builds
  `https://www.kaggle.com/api/v1/datasets/download/...` and calls
  `URLSession.shared.download`.
- It is invoked at runtime from `App/Backend/Configs/AppConfig.swift:225`, not at build time.
- It requires Kaggle API credentials to be present in the app.

Nothing about a patient leaves the device — the request carries only a dataset slug, and
there is a built-in fallback phrase set when the network or credentials are missing. But
for a privacy-positioned medical app this is the wrong shape, and a reviewer will ask
about it:

1. a guardrail whose vocabulary depends on a third-party host is a guardrail that
   behaves differently offline than online;
2. shipping API credentials inside a patient-facing app is a finding in its own right;
3. it contradicts the "offline-first" framing in the demo.

**Recommended fix (small):** run the extraction once on a dev machine, commit the
resulting `medical_anchors.json` as a bundled resource, and delete the runtime download
path. The loader already has the fallback plumbing, so this is mostly deletion.

If there is no time, say it out loud in the presentation as a known limitation with the
fix identified. Being asked about it and having an answer is fine; being caught with it
is not.

---

## Runtime proof — the part that actually convinces a panel

A static scan proves no *intent* to call out. It cannot prove nothing leaves at runtime.
Pair it with a demo the audience can verify with their own eyes:

1. **Pre-stage the device.** Launch the app once with network on, let the model download
   finish, and let `MedicalAnchorLoader` populate its cache. (Model download is legitimate
   egress — do it before the demo, not during it.)
2. **Cut the network on camera.** Airplane Mode on, Wi-Fi off, Cellular off. Show the
   Control Centre toggles on screen. Do not cut away.
3. **Run the full pipeline while offline:**
   - Vietnamese voice input → speech recognition. Recognition is on-device only (§7), so this
     needs a device with Apple's on-device Vietnamese dictation installed; without it the mic
     reports itself unavailable instead of sending audio to Apple. Check before recording;
   - a wound photo from the library → image analysis;
   - a text question → retrieval → cited answer;
   - tap a citation → the source card renders from the bundled `vectorstore.db`;
   - text-to-speech reads the answer back.
4. **Show the answer is grounded, not cached.** Ask something you have not asked before
   in the session, so nobody can claim it was a replayed response.
5. **Optional, strong:** run the same flow with the device connected to a laptop running
   a packet capture (Charles / `tcpdump`), and show zero outbound flows during the turn.
   If you do this, capture from the moment the app launches — a clean capture is only
   meaningful if it covers the whole session.

Record this as a video and keep it in the deck. A live demo can fail for reasons that
have nothing to do with your claim.

## When to re-run

Re-run `Tools/privacy_audit.sh` after any dependency change, and before the presentation.
It exits non-zero when it finds an undeclared egress host, an analytics SDK, iCloud sync,
or a missing file-protection setup — so it can be wired into CI as a guard.
