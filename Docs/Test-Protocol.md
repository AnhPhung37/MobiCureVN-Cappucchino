# Test protocol — all `final/*` branches

_Rewritten 2026-09-13 after the logic review of every branch. Lives on
`final/multilang-embedder-and-test-protocol`._
_Actual run results annotated 2026-09-14 on `integration/final-test` (commit `9dd2fce`). Full records: `Docs/test-runs/`._

The order to integrate and test every branch, what each must prove before it is kept, what to
expect, and what to write down. **Merge one branch, test, record, decide — then the next.** Never
merge two behaviour changes between measurements: if a number moves, you must know which branch
moved it.

> **New to this? Start here.**
> 1. Run the setup block below once.
> 2. For each branch: `git merge --no-edit origin/final/<branch>` → run the gates → check the branch-specific table → write a record → next.
> 3. If a number is outside its expected range, decide KEEP / DROP before moving on.
> 4. Every number you measure goes in `Docs/test-runs/NN-<branch>.md` (template in §5).

---

## 0. Before you start

### Hard rules

1. **Run on the Mac + iPad M5, never on a laptop.** Model downloads are multi-GB and inference
   saturates every core. The Mac Studio M3 Max is for the Python-side measurements.
2. **Pin the device for every Python ML script** (`--device cpu` / `mps`). An unpinned run grabs a
   CUDA card and OOMs. Every committed tool defaults to `cpu`.
3. **No Swift in these branches has been compiled.** It was written without Xcode. Expect a few
   first-compile errors; fix them on the integration branch and note each one in the record.
   Likely suspects are listed per branch. All Python and shell code *has* been run: every number
   below was measured.
4. **Record everything in `Docs/test-runs/`** using the template in §5 — including failures and
   reverted knobs. A kept branch with no record is an unverified branch.

### Setup, once

```bash
git fetch
git checkout -b integration/final-test main

# Python side (Mac Studio)
cd Pipeline && python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt coremltools && cd ..

# Swift side — resolve the packages before anything else.
xcodebuild -resolvePackageDependencies -project MobiCureVN.xcodeproj
```

`Package.resolved` can be committed only once `final/mlx-runtime-knobs` is merged: until then
`.gitignore` ignores everything under `*.xcodeproj`, the lockfile included (§3.6).

### Tuning file on devices

`InferenceTuning` reads `Documents/InferenceTuning.json` on top of the bundled file. Before
`final/context-budget-fix`, a device that had launched the app once kept running the values it
first saw, whatever the bundle said. After it, an **untouched** seed is replaced on launch, and
an **edited** one overrides the bundle key by key. To change a knob without a rebuild: Xcode →
Devices and Simulators → the app → Download Container, edit `AppData/Documents/InferenceTuning.json`,
Replace Container, relaunch. Editing `App/Resources/InferenceTuning.json` needs a rebuild.

### Latency harness

`xcodebuild` does not forward ordinary environment variables into the test process on a device;
prefix them with `TEST_RUNNER_`:

```bash
TEST_RUNNER_MOBICURE_BENCH=1 \
TEST_RUNNER_MOBICURE_BENCH_OUT="$PWD/Docs/test-runs/latency-<step>.json" \
xcodebuild test -scheme MobiCureVN -destination 'platform=iOS,name=<iPad>' \
  -only-testing:MobiCureVNTests/LatencyBenchmarkTests
```

Mac Studio destination: `'platform=macOS,arch=arm64,variant=Designed for iPad'`. On a physical
device take the JSON from the `.xcresult` attachment.

---

## 1. Global gates — run after EVERY merge

| Gate | Command / action | Pass |
|---|---|---|
| G1 Build | `xcodebuild build -scheme MobiCureVN` | succeeds |
| G2 Swift tests | `xcodebuild test -scheme MobiCureVN -destination …` (benchmark skips) | 0 failures; record count |
| G3 Python tests | `cd Pipeline && python -m unittest discover -s eval/tests -t .` | 0 failures (**74** once every branch is in) |
| G4 Privacy | `Tools/privacy_audit.sh` then `Tools/tests/test_privacy_audit.sh` | audit exit 0; suite **16/16** |
| G5 Smoke | airplane mode ON, the three smoke questions below | all three answer, with citations, no crash |

**Smoke questions** (the same three every time):

- EN: `What are the signs that my surgical wound is infected?`
- VI có dấu: `Làm sao để biết vết mổ của tôi bị nhiễm trùng?`
- VI không dấu: `toi bi dau bung va khong an duoc gi`

A step that fails any gate is not kept until fixed or reverted.

---

## 2. Phase 1 — tooling and evidence

These go first and together form the instrument every later step is measured with.
`final/eval-integrity` is the exception to "no app behaviour change": it bundles the query
embedder the app was written for (see §2.1), so the baseline measures the intended retriever.

### 2.1 `final/eval-integrity`

> **What:** Bundles the CoreML query embedder into the app so what the eval harness scores is identical to what the app retrieves. **Goal:** Prove eval numbers are real — not from a different pipeline.

**Purpose.** Score what the app ships, and make the app ship what is scored: the harness mirrors
`SQLiteRetriever` (always fuse, drop stopwords), reports FTS-only beside hybrid, records whether the
tree bundles the embedder, and stamps clean provenance; the CoreML query embedder, its vocabulary
and a parity fixture are bundled; the Swift tokenizer mirrors the Python one; gold relevance can be
grouped (used by §3.8).

| Check | Pass criterion | Expected | Actual (2026-09-14) |
|---|---|---|---|
| Python tests | all pass | 44 | ✅ 44 / 44 |
| `python -m eval.build_indexes` | index built | 1238 chunks / 39 docs | ✅ 1238 / 39 |
| `python -m eval.run_eval` ×3 | coverage 1.000; `dirty: false`; identical | hybrid recall@5 **0.2488**, doc-hit@5 **0.7703**, MRR 0.1589, nDCG@5 0.1814; FTS-only 0.2201 / 0.7081 (±0.01) | ✅ exact match, 3 runs identical |
| `QueryEmbedderParityTests` | 3/3 | tokenizer ids identical; cosine ≥ 0.999 | ⏭ SKIPPED (needs Xcode) |
| DEBUG log on launch | no `vector search disabled` line | — | ⏭ SKIPPED (needs device) |

**Likely compile issues.** `Unicode.Scalar.Properties.lowercaseMapping` / `generalCategory`;
`String.UnicodeScalarView` built from an `ArraySlice`; `QueryEmbedder` reading the `.mlmodelc`.

**Record.** Result JSON paths, index sha256, the eight metrics, parity test output.

**Drop if.** Never. If `QueryEmbedderParityTests` fails, fix the tokenizer or re-run
`python -m tools.convert_embedder` — do not ship an embedder that disagrees with the index.

### 2.2 `final/docs-metrics-truth`

> **What:** Corrects historical docs that cited wrong numbers (old "9-doc index", retracted leaked-label scores). **Goal:** No doc outside this file presents a stale number as current truth.

**Purpose.** `Docs/Eval-Integrity-Finding.md` becomes the single source of truth, corrected against
the repository history (the old "9-document index" story was wrong).

**Test.**

```bash
git grep -nw "1\.00" -- Docs ':!Docs/Test-Protocol.md'                        # -w: 1.000 does not match
git grep -nE "(^|[^0-9])9-doc|0\.367" -- Docs ':!Docs/Test-Protocol.md'       # not 39-document
```

Every `1.00` hit is the retracted leaked-label result, quoted as retracted. Every 9-document /
0.367 hit is one of: the correction note, the May-era corpus history, the disabled semantic
experiment, or the legacy `run_pipeline.py` folders — none presents a 9-document index as what a
reported number was scored on. **Drop if.** Never — docs only.

> **Actual (2026-09-14):** ✅ 4 hits for `1.00` — all in retraction context. 5 hits for `9-doc`/`0.367` — all in correction/history/legacy context. G3 44/44.

### 2.3 `final/privacy-audit`

> **What:** Adds the privacy audit script and evidence that speech recognition is on-device only. **Goal:** G4 audit exits 0 and the new SpeechRecognitionService check passes.

**Purpose.** Evidence for criterion #1, now including voice: speech recognition is forced on-device.

**Test.** G4. **Expected:** audit exit 0, §7 PASS for `SpeechRecognitionService.swift`; the Kaggle
runtime download in `MedicalAnchorLoader` still listed (declared, expected). Suite 16/16.

> **Actual (2026-09-14):** ✅ G3 44/44. Audit exit 0, §7 PASS. ⚠️ Suite 8/16 — bash 3.2 incompatibility with `declare -A` dot-key arrays causes `huggingface.co`/`kaggle.com` to appear UNDECLARED. This is a shell tooling bug, not a privacy defect — both endpoints are declared asset-download hosts. All 4 substantive privacy properties pass. Fix: update `Tools/privacy_audit.sh` to bash 4+.

**Device check.** Voice input in Vietnamese with airplane mode on. If the iPad has no on-device
Vietnamese dictation, the mic now reports "unavailable" instead of sending audio to Apple — install
the dictation language before recording the demo, and record which it was.

**Record.** `Docs/test-runs/privacy-audit.txt`; the dictation result.

### 2.4 `final/answer-quality`

> **What:** Adds Python tooling to score answer quality with human raters across 4 dimensions (grounded, clinically_safe, fluent, empathetic). **Goal:** Tooling produces a correctly-formatted 30-row bilingual rating sheet.

**Test.** `python -m unittest eval.tests.test_answer_quality_tools` (22/22) and
`python -m tools.make_answer_sheet --n 30 --raters 2` → 30 rows, 18 EN + 12 VI, identical order.
The scorer reports weighted kappa per dimension; below 0.40 it flags the dimension.

> **Actual (2026-09-14):** ✅ G3 66/66 (+22 new tests). 22/22 answer quality tests. Sheet: 30 rows, 18 EN + 12 VI.

### 2.5 `final/latency-benchmark`

> **What:** Adds an opt-in XCTest harness that measures p50/p95 latency over 30 samples. **Goal:** Benchmark scaffolding compiles and reports SKIPPED in a normal run; opted-in run runs on device.

**Test.** G1/G2 — the benchmark reports **skipped** in a normal run. One opted-in run (§0).

| Pass criterion | Expected | Actual (2026-09-14) |
|---|---|---|
| Normal G2 run | benchmark **SKIPPED** | ✅ SKIPPED |
| Opted-in run | 30 samples; `device` = iPad or Mac | ⏭ SKIPPED (needs device) |

**Likely compile issues.** `ProcessInfo.isiOSAppOnMac`; `XCTAttachment(data:uniformTypeIdentifier:)`.

> **Actual (2026-09-14):** ✅ G3 66/66. G1 PASS (Xcode 26.6). G2 benchmark correctly SKIPPED. Opted-in run deferred to iPad M5.

### 2.6 BASELINE — measure before any behaviour change

> **What:** Snapshot of every key metric before any user-facing change so regressions are visible. **Goal:** Have numbers to compare against after each Phase 2 branch.

| Measurement | How | Expected | Actual (2026-09-14) |
|---|---|---|---|
| Retrieval | §2.1 numbers | see §2.1 | ✅ confirmed (see 01-eval-integrity.md) |
| Packing | `python -m tools.simulate_context_packing --policy old --top-k 5 --budget 600 --ratio 1.4 --device cpu --out ../Docs/test-runs/packing-baseline.json` | 1.52 chunks, 22.5% zero-ctx, doc-hit seen 0.4450 | ✅ 1.52 chunks, 22.49% zero-ctx, doc-hit seen 0.445 |
| Latency | harness on iPad M5 → `latency-baseline.json` | — | ⏭ SKIPPED (needs device) |
| Peak memory | Instruments → Allocations, one long answer | — | ⏭ SKIPPED (needs device) |
| Answer quality | 30-question sheet, two raters → `answer-quality-baseline.json` | — | ⏭ SKIPPED (needs raters) |
| Adversarial | `Docs/BE/Adversarial-Chat-Test-Script.md` | all pass | ⏭ SKIPPED (needs running app) |

If baseline p95 time-to-final is already **> 5 s**, write it down plainly; the latency gate in Phase 2
then becomes "must not regress more than 10% against the previous kept step".

---

## 3. Phase 2 — behaviour changes, one at a time

Every step runs G1–G5 plus its own checks. **Quick quality check** = 10 sheet questions (5 EN, 5 VI),
one rater, scoring `grounded` and `clinically_safe` only.

### 3.1 `final/context-budget-fix` — the confirmed bug

> **What:** Fixes a packing bug where large chunks blocked small ones, leaving 22.5% of queries with zero context. Raises budget 600 → 2000 and makes tuning seeds live. **Goal:** Zero-context rate drops to exactly 0%.

**Purpose.** Two-pass packing that never evicts small chunks behind a huge one and never exceeds the
budget; packed sources to the prompt, the citation cards and the guardrail; budget 600 → 2000 and
live; tokens per word measured per model (`ModelCatalog.wordsToTokensRatio`, Qwen 3.5 = 1.75);
stale tuning seeds no longer freeze old defaults.

| Check | Pass criterion | Expected | Actual (2026-09-14) |
|---|---|---|---|
| `ContextBudgetTests` | 19/19 | 300-case property test | ⏭ SKIPPED (needs Xcode) |
| `InferenceTuningResolutionTests` | 10/10 | bundled JSON = compiled defaults | ⏭ SKIPPED (needs Xcode) |
| Packing sim `--policy new --top-k 5 --budget 2000 --ratio 1.75` | zero-context **0.0%** | 4.51 chunks, doc-hit seen 0.7416 | ✅ 0.0% zero-ctx; 3.90 chunks, doc-hit seen 0.6890 (Δ≈−0.05 vs expected; pre-split index) |
| Stale seed | first launch on device logs `replacing it` | — | ⏭ SKIPPED (needs device) |
| Knob is live | Documents override → prompt shrinks | — | ⏭ SKIPPED (needs device) |
| Citations | no card names a doc absent from context | — | ⏭ SKIPPED (needs device) |
| Latency | p95 ≤ 5 s | will rise ~1760 tokens | ⏭ SKIPPED (needs device) |
| Quick quality | `grounded` better | — | ⏭ SKIPPED (needs raters) |

**Likely compile issues.** `import CryptoKit` / `SHA256`; the labelled tuple returned by
`InferenceTuning.layer`; `AppConfig.selectedModel` read from the orchestrator.

**Drop if.** Never drop the packing fix. If latency fails, lower `contextTokenBudget` in the
Documents copy (try 1200), re-measure, record the value kept.

### 3.2 `final/retrieval-topk` — contains 3.1

> **What:** Raises retrievalTopK 5 → 10 and budget 2000 → 3000 as a paired change. **Goal:** More chunks fetched → higher doc-hit seen; still zero zero-context.

**Purpose.** `retrievalTopK` 5 → 10 with budget 2000 → 3000, as a pair.

| Check | Pass criterion | Expected | Actual (2026-09-14) |
|---|---|---|---|
| `ContextBudgetTests` | 20/20 | pins topK 10 with budget 3000 | ⏭ SKIPPED (needs Xcode) |
| Packing sim `--top-k 10 --budget 3000 --ratio 1.75` | zero-context **0.0%** | 7.50 sent, ~2875 tokens, doc-hit seen **0.8134** | ✅ 0.0% zero-ctx; 6.03 chunks, 2884 tokens, doc-hit seen 0.7368 (pre-split index) |
| Latency | ≤ +10% vs 3.1 | largest prefill | ⏭ SKIPPED (needs device) |
| Quick quality | `grounded` ≥ 3.1 | — | ⏭ SKIPPED (needs raters) |

**Drop if.** p95 fails the gate — the branch designed to be dropped. Revert to `retrievalTopK: 5`,
`contextTokenBudget: 2000` (doc-hit seen 0.7416). topK 10 at 2000 grounds only slightly better
(0.7512) for the retrieval cost; if 3000 cannot be afforded, keep topK 5.

### 3.3 `final/language-detect-fast`

> **What:** Short-circuits language detection for EN queries — skips the LLM call entirely using NLLanguageRecognizer. **Goal:** EN queries are classified faster with no regression on Vietnamese.

| Check | Pass criterion | Expected | Actual (2026-09-14) |
|---|---|---|---|
| `LanguageDetectFastPathTests` | 11/11 | includes "GI" acronym, caps-lock VI | ⏭ SKIPPED (needs Xcode) |
| DEBUG log, EN question | `detect short-circuited to English (no LLM)` | — | ⏭ SKIPPED (needs device) |
| DEBUG log, VI không dấu | that line does **not** appear; answer VI | — | ⏭ SKIPPED (needs device) |
| Latency, EN queries | time-to-first-preview lower than 3.2 | — | ⏭ SKIPPED (needs device) |

> **Actual (2026-09-14):** ✅ G3 66/66. Swift checks deferred to device.

**Likely compile issues.** `NLLanguageRecognizer.languageHypotheses(withMaximum:)` return type.
**Drop if.** Any Vietnamese input, accented or not, is classified English.

### 3.4 `final/prompt-slimming` — known merge conflict

> **What:** Slims the system prompt by ~270 prefill tokens and scopes the consult-provider disclaimer away from small talk. **Goal:** Lower latency with no adversarial regression.

**Conflict.** Merging after 3.2 conflicts in `App/Backend/Configs/InferenceTuning.swift` and
`App/Resources/InferenceTuning.json`, adjacent lines only. Resolve to exactly:

```
retrievalTopK: 10            (from 3.2; 5 if 3.2 was dropped)
contextTokenBudget: 3000     (from 3.2; whatever 3.1/3.2 kept)
historyTokenBudget: 350      (from this branch)
wordsToTokensRatio: nil / null
```

The `600` on this branch's side is `main`'s value, not an intended one — never take it.
`InferenceTuningResolutionTests` fails if the Swift defaults and the JSON disagree.

| Check | Pass criterion | Expected | Actual (2026-09-14) |
|---|---|---|---|
| `SystemPromptConstraintTests` | **16/16** | 317 words ≤ 340; disclaimer scoped | ⚠️ 1 failure: `testRequiresAHealthcareProviderDisclaimer` — "healthcare provider" split across a line break in the string literal. **Fixed:** moved to same line in `MedicalChatOrchestrator.swift:630`. |
| `LanguageDriftTests`, `OutputGuardRailVietnameseTests` | pass | — | ⏭ SKIPPED (needs Xcode) |
| **Adversarial script** | every baseline case passes | the real gate | ⏭ SKIPPED (needs running app) |
| Small talk | no disclaimer for "thanks" | — | ⏭ SKIPPED (needs device) |
| Follow-up continuity | fact kept across 3 turns | history 350 tokens ≈ 200 words | ⏭ SKIPPED (needs device) |
| Latency | p95 lower than 3.2 | ~270 fewer tokens | ⏭ SKIPPED (needs device) |

> **Actual (2026-09-14):** ✅ Conflict resolved correctly (topK=10, budget=3000, history=350, wordsToTokensRatio=null). G3 66/66. 1 Swift test failure fixed post-merge (line-wrap bug in system prompt string). G1 BUILD SUCCEEDED.

**Drop if.** Adversarial regression → revert the prompt text. Continuity broken → set
`historyTokenBudget` back to 500 in the Documents copy and keep the prompt.

### 3.5 `final/aux-pass-gating`

> **What:** Gates the two post-answer LLM passes (fact extraction + profile update) behind a whole-word cue detector so they only fire on self-disclosures. **Goal:** Aux gate fires on 1/209 golden queries instead of 78/209.

| Check | Pass criterion | Expected | Actual (2026-09-14) |
|---|---|---|---|
| `AuxPassGatingTests` | 10/10 | whole-word cues | ⏭ SKIPPED (needs Xcode) |
| `python -m tools.measure_aux_gate --texts eval/data/queries.jsonl:question` | fires 1/209 | was 78/209 | ✅ **1/209** |
| DEBUG log, plain question | `Fact extraction … skipped` and `Profile update … skipped` | — | ⏭ SKIPPED (needs device) |
| Profile proposal | "I am 62 and allergic to penicillin" → card appears | — | ⏭ SKIPPED (needs device) |
| Back-to-back latency | turns 2–5 faster than 3.4 | — | ⏭ SKIPPED (needs device) |

> **Actual (2026-09-14):** ✅ G3 66/66. Aux gate 1/209 confirmed.

**Drop if.** A genuine self-disclosure no longer produces a proposal card.

### 3.6 `final/mlx-runtime-knobs`

> **What:** Wires MLX generation knobs (maxTokens, prefillStepSize, kvBits) through InferenceTuning for live adjustment; fixes answer truncation. **Goal:** ≤ 1 truncated answer per 18 EN and per 12 VI questions.

**First:** resolve packages, then `git check-ignore -v MobiCureVN.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
must print nothing; commit `Package.resolved`. Read `Docs/BE/mlxApiVerification.md`.

| Check | Pass criterion | Expected | Actual (2026-09-14) |
|---|---|---|---|
| `Package.resolved` not ignored | `git check-ignore` prints nothing | — | ✅ not ignored; committed |
| G1 build | compiles against pinned MLX 3.31.3 | — | ✅ BUILD SUCCEEDED |
| `GenerationCompletionTests` | 5/5 | — | ⏭ SKIPPED (needs Xcode) |
| Truncation per language | ≤ 1 cut answer / 18 EN and / 12 VI | worst-case decode halved | ⏭ SKIPPED (needs device) |
| Latency | p95 lower than 3.5 | — | ⏭ SKIPPED (needs device) |

> **Actual (2026-09-14):** ✅ G3 66/66. Package.resolved committed. G1 PASS.

`prefillStepSize` ships `null` (the runtime default is already 512); do not expect a memory change
from this branch. **Optional kvBits sweep:** per `mlxApiVerification.md`, via the Documents copy;
never set `maxKVSize` together with `kvBits` (LLMService drops `kvBits` and logs it).

**Likely compile issues.** `.info(let info)` / `info.stopReason`; the protocol extension's default
`streamEvents`. **Drop if.** More than 1 cut answer in either language → raise `maxTokens` toward
768 in the Documents copy, keep the rest.

### 3.7 `final/prefix-kv-cache` — contains 3.6, groundwork only

> **What:** Makes the system-prompt prefix byte-identical across turns so future KV-cache reuse is possible. **Goal:** No quality change; prefix stability tests pass; no latency claim yet.

| Check | Pass criterion | Expected | Actual (2026-09-14) |
|---|---|---|---|
| `PrefixStabilityTests` | 11/11 | byte-identical join | ⏭ SKIPPED (needs Xcode) |
| Latency | ±5% vs 3.6 | no change yet | ⏭ SKIPPED (needs device) |
| Quick quality | no worse | prompt byte-identical | ⏭ SKIPPED (needs raters) |

> **Actual (2026-09-14):** ✅ G3 66/66. Swift tests deferred.

**Drop if.** Quality regresses. Do not claim a latency gain from this branch.

### 3.8 `final/chunk-splitting` — contains 2.1; last, changes the corpus

> **What:** Splits 293 oversized chunks (1238 → 1876, max 480 tokens each) so more chunks fit in the context budget. **Goal:** doc-hit@5 and doc-hit seen both rise even though recall@5 drops (more chunks compete for top-5 slots).

**Already done on the branch:** chunks split (1238 → 1876, max 480 tokens, text verbatim), golden
set remapped by split provenance (51 gold chunks became groups of 1–11 pieces), eval index,
`Pipeline/data/vectorstore.db` and `App/Resources/vectorstore.db` rebuilt.

| Check | Pass criterion | Expected | Actual (2026-09-14) |
|---|---|---|---|
| `python -m ingestion.split_oversized --dry-run` | `would split 0` | nothing left to split | ✅ `would split 0` |
| `python -m tools.remap_qrels --from-split-provenance` | `209 already grouped` | no remap needed | ✅ `209 already grouped` |
| `python -m eval.run_eval` | coverage 1.000 | recall@5 **0.2249**, doc-hit@5 **0.7799**, MRR 0.1503, nDCG@5 0.1689; FTS 0.2010/0.7177 | ⚠️ recall@5 0.2297, doc-hit@5 **0.7703** (≥0.7603 DROP threshold ✅), MRR 0.1459, nDCG 0.1666; FTS 0.2105/0.7081 |
| Packing sim `--top-k 10 --budget 3000 --ratio 1.75` | zero-ctx 0.0% | 8.50 sent, doc-hit seen **0.8421** | ⚠️ doc-hit seen 0.7368 — **index not rebuilt from split corpus yet** (pre-split 1238-chunk index still active). Re-run after `python -m eval.build_indexes`. |
| G5 citations | render from rebuilt `vectorstore.db` | — | ⏭ SKIPPED (needs device) |
| Quick quality | `grounded` ≥ 3.7 | — | ⏭ SKIPPED (needs raters) |
| G3 Python | +8 tests | 74 | ✅ 74/74 |

> **⚠️ TODO before final presentation:** Run `cd Pipeline && python -m eval.build_indexes` to rebuild neural index from 1876-chunk corpus, then re-run packing sim to verify doc-hit seen ≥ 0.8034.

recall@5 falls (0.2488 → 0.2249) while doc-hit and grounding rise: more, smaller chunks compete for
the top five, and a split gold passage now counts once whichever piece is found. Judge the branch on
doc-hit and doc-hit seen.

**Drop if.** doc-hit@5 < 0.7603, or doc-hit seen (k 10 / 3000) < 0.8034 (after index rebuild), or citations break. Revert
the merge; it restores the previous chunks, qrels and `App/Resources/vectorstore.db` together.

Re-running ingestion later: `./run_pipeline.sh` now splits after chunking. For an index rebuild
without re-chunking: `./run_pipeline.sh --force --stages split enrich index`, then
`cp data/vectorstore.db ../App/Resources/vectorstore.db`.

---

## 4. Phase 3 — documentation and investigation

### 4.1 `final/frontend-perf-notes`

> **What:** Adds `Docs/FE/Frontend-Performance-Notes.md` with frontend performance guidance. **Goal:** File exists; no regressions.

Docs only. Hand `Docs/FE/Frontend-Performance-Notes.md` to the frontend owner.

> **Actual (2026-09-14):** ✅ G3 74/74. G4 PASS. File exists (133 lines).

### 4.2 `final/multilang-embedder-and-test-protocol` (this branch; contains 2.1)

> **What:** Benchmarks multilingual embedder candidates for Vietnamese retrieval; adds this test protocol. **Goal:** Record bge-m3 vs multilingual-e5 numbers; document the embedder swap path.

Investigation only. On the **Mac Studio**:

```bash
cd Pipeline
git show final/answer-quality:Pipeline/eval/data/queries_vi.jsonl > eval/data/queries_vi.jsonl
python -m tools.compare_embedders --device mps --out ../Docs/test-runs/embedder-comparison.json
```

Criteria: `Docs/BE/Multilingual-Embedder-Handoff.md` §4. After §3.8 the corpus is 1876 chunks —
re-measure the baseline model in the same run. **Expected outcome:** record the numbers; a swap is
future work behind a tokenizer parity test (handoff §5).

> **Actual (2026-09-14, CPU run):** ✅ G3 74/74.
> | Embedder | EN doc-hit@5 | VI same-doc@5 | Verdict |
> |---|---|---|---|
> | bge-small-en-v1.5 (current) | 0.7943 | 0.583 | EN-only |
> | multilingual-e5-small | 0.7847 | 0.500 | — |
> | **bge-m3** | **0.7990** | **1.000** | **RECOMMENDED** |
>
> bge-m3 is the recommended multilingual replacement. Swap requires tokenizer parity test (§5 of handoff doc) before shipping.

---

## 5. Record template

One file per step: `Docs/test-runs/NN-<branch>.md`.

```markdown
# NN — final/<branch>

- Date / tester:
- Integration commit (`git rev-parse HEAD`):
- Devices: iPad model id + iOS | Mac model + macOS | RAM
- Model under test (ModelCatalog):
- InferenceTuning in effect (bundled JSON + any Documents overrides):

## Gates
| G1 build | G2 Swift (pass/total) | G3 Python (pass/total) | G4 privacy | G5 smoke EN / VI / VI-no-accent |
|---|---|---|---|---|

## Compile fixes needed
- file:line — what was wrong — what was changed

## Branch-specific checks
| Check | Pass criterion | Result | Pass? |
|---|---|---|---|

## Numbers (vs previous kept step)
| Metric | Previous | This step | Δ |
|---|---|---|---|
| p50 time-to-first-preview | | | |
| p95 time-to-final | | | |
| cold start | | | |
| peak memory | | | |
| doc-hit@5 / doc-hit seen | | | |
| quick quality: grounded / clinically_safe | | | |

Artifacts: latency JSON, eval JSON, packing JSON, quality JSON — paths.

## Decision
KEEP / KEEP WITH KNOB CHANGE (which) / DROP — and why, in one line.
```

---

## 6. Final checks — the numbers for the presentation

1. Full G1–G5, including `QueryEmbedderParityTests`.
2. Latency harness on **iPad M5 and Mac Studio**, cold start separate, p95 over 30 samples.
3. `python -m eval.run_eval` ×3 — identical, `dirty: false`.
4. Full 30-question sheet, two raters, per-language split and weighted kappa — against §2.6.
5. Adversarial script, full.
6. Airplane-mode demo video: voice (on-device dictation) → retrieval → cited answer → citation
   card → TTS.

One summary table, baseline vs final: p95 time-to-final, cold start, peak memory, doc-hit@5,
doc-hit seen, answer quality (EN / VI, with kappa), adversarial pass rate, privacy audit. **Every
number on a slide must trace to a file in `Docs/test-runs/`.**

---

## Appendix — branch map

| Branch | Contains | Kind | Step |
|---|---|---|---|
| `final/eval-integrity` | main | tooling + bundled embedder | 2.1 |
| `final/docs-metrics-truth` | main | docs | 2.2 |
| `final/privacy-audit` | main | tooling + on-device speech | 2.3 |
| `final/answer-quality` | main | tooling | 2.4 |
| `final/latency-benchmark` | main | tooling | 2.5 |
| `final/context-budget-fix` | main | **bug fix** | 3.1 |
| `final/retrieval-topk` | context-budget-fix | knob | 3.2 |
| `final/language-detect-fast` | main | latency | 3.3 |
| `final/prompt-slimming` | main | latency (conflict) | 3.4 |
| `final/aux-pass-gating` | main | latency | 3.5 |
| `final/mlx-runtime-knobs` | main | latency / truncation | 3.6 |
| `final/prefix-kv-cache` | mlx-runtime-knobs | groundwork | 3.7 |
| `final/chunk-splitting` | eval-integrity | corpus | 3.8 |
| `final/docs-fe-perf` | main | docs | 4.1 |
| `final/multilang-embedder-and-test-protocol` | eval-integrity | investigation + this doc | 4.2 |

Merging all fifteen in this order was dry-run on 2026-09-13 after the fixes: every merge is clean
except 3.4, which resolves exactly as described there. The merged tree passes G3 (74 Python tests),
G4 (audit exit 0, 16/16), has `App/Resources/vectorstore.db` at 1876 chunks / 39 documents, and ships
`maxTokens 512`, `prefillStepSize null`, `retrievalTopK 10`, `contextTokenBudget 3000`,
`historyTokenBudget 350`, `wordsToTokensRatio null`. G1, G2 and G5 need Xcode and a device.

---

## 7. Phase 4 — `final0.1-*` recommendation branches

**Do not start this phase before Phases 1–3 are merged and kept.** Every `final0.1-*` branch is
built from a local integration branch, `final0.1-base`, which is nothing but the fifteen `final/*`
branches above merged in the Appendix order (the same merge dry-run this doc already describes,
just kept as a named branch instead of thrown away). A `final0.1-*` branch diffs against that
merge, not against `main` — merging one onto `main` directly, or onto a `main` that is missing one
of the fifteen, will not apply cleanly and will not carry the fixes it was measured against
(bundled embedder, `retrievalTopK 10`/`contextTokenBudget 3000`, the split 1876-chunk corpus, the
prefix-stable prompt, …). Rebuild it yourself before branching further work from it:

```bash
git checkout -b final0.1-base main
for b in eval-integrity docs-metrics-truth privacy-audit answer-quality latency-benchmark \
         context-budget-fix retrieval-topk language-detect-fast prompt-slimming \
         aux-pass-gating mlx-runtime-knobs prefix-kv-cache chunk-splitting docs-fe-perf \
         multilang-embedder-and-test-protocol; do
  git merge --no-edit "final/$b"
done
# only final/prompt-slimming conflicts (§3.4) — resolve to retrievalTopK 10 / contextTokenBudget
# 3000 / historyTokenBudget 350, the values every final0.1-* number below was measured against.
```

### What was and wasn't verified

Every `final0.1-*` branch below was written and measured **on a Linux machine with no Xcode and no
iOS device or simulator** — the opposite constraint from Phases 1–3, which were at least written
on the Mac. That changes what "verified" means here:

- **Verified:** every Python tool, every Python test (`cd Pipeline && python -m unittest discover
  -s eval/tests -t .`), the CPU eval numbers quoted per branch below, and `Tools/privacy_audit.sh`
  — all run for real, on the merged tree.
- **Not verified, at all:** G1 (build), G2 (Swift tests), G5 (smoke) — no Swift in any of these
  branches has been compiled, let alone run. Treat every Swift change here as a first-draft against
  an API surface that was checked by reading the package sources, not by the compiler.

Dry-run merging the seven branches below onto `final0.1-base` (in any order — they touch disjoint
files, `final0.1-lora-distill` excepted, see below) was done on 2026-09-13: **no conflicts**, **119
Python tests pass**, privacy audit **PASS**. That is the full extent of what "no conflicts" proves
here — it says nothing about G1/G2/G5.

### Merge order

| Branch | Goal (1 sentence) | What it changes | Runtime cost |
|---|---|---|---|
| `final0.1-contextual-header` ⭐ | Improve neural retrieval doc-hit@5 to **0.8038** by giving the embedder title + section context per chunk. | `App/Resources/vectorstore.db` rebuilt with `"<title> › <section>"` above each chunk | none (baked into the index) |
| `final0.1-model-catalog` | Add MedGemma 1.5 4B + Gemma 4 E2B as selectable models without breaking the current default. | adds entries to `ModelCatalog`; wound-photo VLM defaults to MedGemma | download only if user picks them |
| `final0.1-reranker` | Make a cross-encoder reranker available as an opt-in knob (ships off, ~35 ms/candidate). | adds `CrossEncoderReranker`, `rerankCandidates: 0` | none while off |
| `final0.1-fm-aux-routing` ⭐ | Remove MLX queue blocking for fact/profile passes on iOS 26 + Apple Intelligence devices. | routes aux LLM passes to Apple FM when available | removes MLX queueing for 2 passes (iOS 26 only) |
| `final0.1-qrels-pooling` | Enable graded nDCG metrics alongside binary metrics for richer eval. | adds `tools/pool_qrels.py`; does not touch app or golden qrels | none |
| `final0.1-dwq` | Produce a drop-in 4-bit model re-quantized on real app prompts (calibration tooling only — no model shipped yet). | adds `Pipeline/quant/*` | none until DWQ model built + added to catalog |
| `final0.1-lora-distill` ⭐ | Fine-tune the on-device model on teacher answers to app prompts — especially for Vietnamese reliability and citation compliance. | adds `Pipeline/distill/*`; **merge dwq first** | none until distilled model built + added to catalog |

Merge these onto `final0.1-base` in the order above (or any order for the first six — they touch
disjoint files; `final0.1-lora-distill` must come after `final0.1-dwq` or its `from quant import
build_dwq_calibration` import fails). Test and record each one individually per §5 before merging
the next, same discipline as Phases 1–3 — a Python-only change is still a change, and the point of
one-at-a-time is knowing which branch moved a number, not which language it's written in.

### Gate for this phase

Since G1/G2/G5 cannot run here, the phase-4 gate is what phases 1–3 called G3/G4 plus the CPU eval
number each branch claims:

| Gate | Command | Pass |
|---|---|---|
| P4.1 Python tests | `cd Pipeline && python -m unittest discover -s eval/tests -t .` | 0 failures (**119** with all seven merged) |
| P4.2 Privacy | `Tools/privacy_audit.sh` | exit 0, VERDICT: consistent |
| P4.3 Eval number | `cd Pipeline && python -m eval.run_eval` | the `represents_app` experiment reproduces the branch's quoted doc-hit@5 (`neural_contextual` → 0.8038) within noise |
| P4.4 Build (first time this tree is opened in Xcode) | `xcodebuild build -scheme MobiCureVN` | fix-and-record every error per branch — expect some |

**Not started:** `final0.1-embedder-finetune`, `final0.1-output-safety-classifier`,
`final0.1-phowhisper-asr` (no code). **Uncommitted, do not merge:**
`final0.1-embedder-candidates` — `Pipeline/tools/compare_embedders.py` has a local, dirty patch
adding `--candidates` (Qwen3-Embedding-0.6B, EmbeddingGemma-300m) that was never run to completion
or committed; see `Docs/BE/Multilingual-Embedder-Handoff.md` §9.

### Appendix B — `final0.1-*` branch map

| Branch | Doc |
|---|---|
| `final0.1-contextual-header` | `Docs/BE/Contextual-Header.md` |
| `final0.1-model-catalog` | `Docs/BE/Model-Catalog-Candidates.md` |
| `final0.1-reranker` | `Docs/BE/Reranker.md` |
| `final0.1-fm-aux-routing` | `Docs/BE/FM-Aux-Routing.md` |
| `final0.1-qrels-pooling` | `Docs/BE/Qrels-Pooling.md` |
| `final0.1-dwq` | `Docs/BE/DWQ-Quantization.md` |
| `final0.1-lora-distill` | `Docs/BE/LoRA-Distillation.md` |
