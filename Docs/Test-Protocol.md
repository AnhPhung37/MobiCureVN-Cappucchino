# Test protocol — all `final/*` branches

_Rewritten 2026-09-13 after the logic review of every branch. Lives on
`final/multilang-embedder-and-test-protocol`._

The order to integrate and test every branch, what each must prove before it is kept, what to
expect, and what to write down. **Merge one branch, test, record, decide — then the next.** Never
merge two behaviour changes between measurements: if a number moves, you must know which branch
moved it.

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

**Purpose.** Score what the app ships, and make the app ship what is scored: the harness mirrors
`SQLiteRetriever` (always fuse, drop stopwords), reports FTS-only beside hybrid, records whether the
tree bundles the embedder, and stamps clean provenance; the CoreML query embedder, its vocabulary
and a parity fixture are bundled; the Swift tokenizer mirrors the Python one; gold relevance can be
grouped (used by §3.8).

| Check | Pass criterion | Expected |
|---|---|---|
| Python tests | all pass | 44 on this branch |
| `python -m eval.build_indexes` | index built | 1238 chunks / 39 docs |
| `python -m eval.run_eval` ×3 | coverage 1.000; `dirty: false`; identical metrics | hybrid recall@5 **0.2488**, doc-hit@5 **0.7703**, MRR 0.1589, nDCG@5 0.1814; FTS-only 0.2201 / 0.7081 / 0.1300 / 0.1525 (±0.01 across machines) |
| `QueryEmbedderParityTests` (device or simulator) | 3/3 | tokenizer ids identical; embedding cosine ≥ 0.999 |
| DEBUG log on launch | no `vector search disabled, FTS-only` line | — |

**Likely compile issues.** `Unicode.Scalar.Properties.lowercaseMapping` / `generalCategory`;
`String.UnicodeScalarView` built from an `ArraySlice`; `QueryEmbedder` reading the `.mlmodelc`.

**Record.** Result JSON paths, index sha256, the eight metrics, parity test output.

**Drop if.** Never. If `QueryEmbedderParityTests` fails, fix the tokenizer or re-run
`python -m tools.convert_embedder` — do not ship an embedder that disagrees with the index.

### 2.2 `final/docs-metrics-truth`

**Purpose.** `Docs/Eval-Integrity-Finding.md` becomes the single source of truth, corrected against
the repository history (the old "9-document index" story was wrong).

**Test.**

```bash
git grep -nw "1\.00" -- Docs                        # -w: 1.000 coverage figures do not match
git grep -nE "(^|[^0-9])9-doc|0\.367" -- Docs       # not 39-document
```

Every `1.00` hit is the retracted leaked-label result, quoted as retracted. Every 9-document /
0.367 hit is one of: the correction note, the May-era corpus history, the disabled semantic
experiment, or the legacy `run_pipeline.py` folders — none presents a 9-document index as what a
reported number was scored on. **Drop if.** Never — docs only.

### 2.3 `final/privacy-audit`

**Purpose.** Evidence for criterion #1, now including voice: speech recognition is forced on-device.

**Test.** G4. **Expected:** audit exit 0, §7 PASS for `SpeechRecognitionService.swift`; the Kaggle
runtime download in `MedicalAnchorLoader` still listed (declared, expected). Suite 16/16.

**Device check.** Voice input in Vietnamese with airplane mode on. If the iPad has no on-device
Vietnamese dictation, the mic now reports "unavailable" instead of sending audio to Apple — install
the dictation language before recording the demo, and record which it was.

**Record.** `Docs/test-runs/privacy-audit.txt`; the dictation result.

### 2.4 `final/answer-quality`

**Test.** `python -m unittest eval.tests.test_answer_quality_tools` (22/22) and
`python -m tools.make_answer_sheet --n 30 --raters 2` → 30 rows, 18 EN + 12 VI, identical order.
The scorer reports weighted kappa per dimension; below 0.40 it flags the dimension.

### 2.5 `final/latency-benchmark`

**Test.** G1/G2 — the benchmark reports **skipped** in a normal run. One opted-in run (§0).

| Pass criterion | Expected |
|---|---|
| opted-in run | 30 samples (3 passes × 10 queries); `device` names the iPad (`iPad…`) or the Mac (`Mac…`) |

**Likely compile issues.** `ProcessInfo.isiOSAppOnMac`; `XCTAttachment(data:uniformTypeIdentifier:)`.

### 2.6 BASELINE — measure before any behaviour change

| Measurement | How |
|---|---|
| Retrieval | §2.1 numbers |
| Packing | `python -m tools.simulate_context_packing --policy old --top-k 5 --budget 600 --ratio 1.4 --device mps --out ../Docs/test-runs/packing-baseline.json` — expect **1.52 chunks sent, 22.5% zero-context, doc-hit seen 0.4450** |
| Latency | harness on iPad M5, default model → `latency-baseline.json` |
| Peak memory | Instruments → Allocations, one long answer, iPad M5 |
| Answer quality | 30-question sheet, two raters (one native Vietnamese speaker) → `score_answer_sheet --out ../Docs/test-runs/answer-quality-baseline.json` |
| Adversarial | `Docs/BE/Adversarial-Chat-Test-Script.md`, pass/fail per case |

If baseline p95 time-to-final is already **> 5 s**, write it down plainly; the latency gate in Phase 2
then becomes "must not regress more than 10% against the previous kept step".

---

## 3. Phase 2 — behaviour changes, one at a time

Every step runs G1–G5 plus its own checks. **Quick quality check** = 10 sheet questions (5 EN, 5 VI),
one rater, scoring `grounded` and `clinically_safe` only.

### 3.1 `final/context-budget-fix` — the confirmed bug

**Purpose.** Two-pass packing that never evicts small chunks behind a huge one and never exceeds the
budget; packed sources to the prompt, the citation cards and the guardrail; budget 600 → 2000 and
live; tokens per word measured per model (`ModelCatalog.wordsToTokensRatio`, Qwen 3.5 = 1.75);
stale tuning seeds no longer freeze old defaults.

| Check | Pass criterion | Expected |
|---|---|---|
| `ContextBudgetTests` | 19/19 | includes a 300-case property test |
| `InferenceTuningResolutionTests` | 10/10 | bundled JSON equals compiled defaults |
| Packing sim `--policy new --top-k 5 --budget 2000 --ratio 1.75` | zero-context 0.0% | **4.51 chunks sent, doc-hit seen 0.7416** |
| Stale seed | on a device that ran `main`, first launch logs `unedited seed from an earlier build — replacing it` and runs budget 2000 | — |
| Knob is live | set `contextTokenBudget` 800 in the Documents copy (§0), relaunch: log says `Documents file overrides the bundle` and the prompt shrinks; restore | — |
| Citations | no citation card names a document absent from the prompt's context (DEBUG log) | — |
| Latency | p95 ≤ 5 s (or ≤ +10%) | **will rise**: ~1760 estimated context tokens |
| Quick quality | `clinically_safe` no worse, `grounded` better | — |

**Likely compile issues.** `import CryptoKit` / `SHA256`; the labelled tuple returned by
`InferenceTuning.layer`; `AppConfig.selectedModel` read from the orchestrator.

**Drop if.** Never drop the packing fix. If latency fails, lower `contextTokenBudget` in the
Documents copy (try 1200), re-measure, record the value kept.

### 3.2 `final/retrieval-topk` — contains 3.1

**Purpose.** `retrievalTopK` 5 → 10 with budget 2000 → 3000, as a pair.

| Check | Pass criterion | Expected |
|---|---|---|
| `ContextBudgetTests` | 20/20 | pins topK 10 with budget 3000 |
| Packing sim `--top-k 10 --budget 3000 --ratio 1.75` | zero-context 0.0% | **7.50 sent, ~2875 est. tokens, doc-hit seen 0.8134** |
| Latency | as 3.1, against 3.1 | the largest prefill of any step |
| Quick quality | `grounded` ≥ 3.1 | — |

**Drop if.** p95 fails the gate — the branch designed to be dropped. Revert to `retrievalTopK: 5`,
`contextTokenBudget: 2000` (doc-hit seen 0.7416). topK 10 at 2000 grounds only slightly better
(0.7512) for the retrieval cost; if 3000 cannot be afforded, keep topK 5.

### 3.3 `final/language-detect-fast`

| Check | Pass criterion | Expected |
|---|---|---|
| `LanguageDetectFastPathTests` | 11/11 | includes "GI" acronym and caps-lock Vietnamese |
| DEBUG log, EN smoke question | `detect short-circuited to English (no LLM)` | — |
| DEBUG log, VI không dấu smoke question | that line does **not** appear; answer Vietnamese | — |
| Latency, EN queries | time-to-first-preview lower than previous step | — |

**Likely compile issues.** `NLLanguageRecognizer.languageHypotheses(withMaximum:)` return type.
**Drop if.** Any Vietnamese input, accented or not, is classified English.

### 3.4 `final/prompt-slimming` — known merge conflict

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

| Check | Pass criterion | Expected |
|---|---|---|
| `SystemPromptConstraintTests` | 16/16 | 317 words ≤ 340; disclaimer scoped away from small talk |
| `LanguageDriftTests`, `OutputGuardRailVietnameseTests` | pass | — |
| **Adversarial script** | every case that passed at baseline still passes | the real gate |
| Small talk | "thanks, that helps" gets no medical disclaimer | — |
| Follow-up continuity | 3 turns: state a fact, two follow-ups | fact kept (350 estimated tokens ≈ 200 words on Qwen 3.5) |
| Latency | p95 lower than previous step | ~270 fewer prefill tokens |

**Drop if.** Adversarial regression → revert the prompt text. Continuity broken → set
`historyTokenBudget` back to 500 in the Documents copy and keep the prompt.

### 3.5 `final/aux-pass-gating`

| Check | Pass criterion | Expected |
|---|---|---|
| `AuxPassGatingTests` | 10/10 | whole-word cues; profile pass uses `.extraction` |
| `python -m tools.measure_aux_gate --texts eval/data/queries.jsonl:question` | — | fires on **1/209** golden questions (was 78/209) |
| DEBUG log after a plain question | `6 · Fact extraction … skipped` and `7 · Profile update proposals … skipped` | — |
| Profile proposal | "I am 62 years old and allergic to penicillin" | confirmation card appears |
| Back-to-back latency | 5 questions without waiting; turns 2–5 time-to-first-preview | lower than previous step |

**Drop if.** A genuine self-disclosure no longer produces a proposal card.

### 3.6 `final/mlx-runtime-knobs`

**First:** resolve packages, then `git check-ignore -v MobiCureVN.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
must print nothing; commit `Package.resolved`. Read `Docs/BE/mlxApiVerification.md`.

| Check | Pass criterion | Expected |
|---|---|---|
| G1 build | compiles against the pinned MLX | property names verified against 3.31.3 |
| `GenerationCompletionTests` | 5/5 | — |
| Truncation, **per language** | all 30 sheet questions; count answers ending in the "cut off" notice | ≤ 1 of 18 EN **and** ≤ 1 of 12 VI |
| Cut answers | end with the notice and the healthcare-provider line | — |
| Latency | p95 lower than previous step | worst-case decode halved |

`prefillStepSize` ships `null` (the runtime default is already 512); do not expect a memory change
from this branch. **Optional kvBits sweep:** per `mlxApiVerification.md`, via the Documents copy;
never set `maxKVSize` together with `kvBits` (LLMService drops `kvBits` and logs it).

**Likely compile issues.** `.info(let info)` / `info.stopReason`; the protocol extension's default
`streamEvents`. **Drop if.** More than 1 cut answer in either language → raise `maxTokens` toward
768 in the Documents copy, keep the rest.

### 3.7 `final/prefix-kv-cache` — contains 3.6, groundwork only

| Check | Pass criterion | Expected |
|---|---|---|
| `PrefixStabilityTests` | 11/11 | includes the byte-identical join |
| Latency | no meaningful change (±5%) | nothing is cached yet |
| Quick quality | no worse | the prompt is byte-identical to the previous step's |

**Drop if.** Quality regresses. Do not claim a latency gain from this branch.

### 3.8 `final/chunk-splitting` — contains 2.1; last, changes the corpus

**Already done on the branch:** chunks split (1238 → 1876, max 480 tokens, text verbatim), golden
set remapped by split provenance (51 gold chunks became groups of 1–11 pieces), eval index,
`Pipeline/data/vectorstore.db` and `App/Resources/vectorstore.db` rebuilt.

| Check | Pass criterion | Expected |
|---|---|---|
| `python -m ingestion.split_oversized --dry-run` | nothing left to split | `would split 0` |
| `python -m tools.remap_qrels --from-split-provenance` | no remap needed | `209 already grouped` |
| `python -m eval.run_eval` | coverage 1.000 | hybrid recall@5 **0.2249** (group-aware), doc-hit@5 **0.7799**, MRR 0.1503, nDCG@5 0.1689; FTS-only 0.2010 / 0.7177 |
| Packing sim `--top-k 10 --budget 3000 --ratio 1.75` | zero-context 0.0% | **8.50 sent, doc-hit seen 0.8421** (0.7751 at k 5 / 2000) |
| G5 | citations render from the rebuilt `vectorstore.db` | — |
| Quick quality | `grounded` ≥ previous step | — |

recall@5 falls (0.2488 → 0.2249) while doc-hit and grounding rise: more, smaller chunks compete for
the top five, and a split gold passage now counts once whichever piece is found. Judge the branch on
doc-hit and doc-hit seen.

**Drop if.** doc-hit@5 < 0.7603, or doc-hit seen (k 10 / 3000) < 0.8034, or citations break. Revert
the merge; it restores the previous chunks, qrels and `App/Resources/vectorstore.db` together.

Re-running ingestion later: `./run_pipeline.sh` now splits after chunking. For an index rebuild
without re-chunking: `./run_pipeline.sh --force --stages split enrich index`, then
`cp data/vectorstore.db ../App/Resources/vectorstore.db`.

---

## 4. Phase 3 — documentation and investigation

### 4.1 `final/frontend-perf-notes`

Docs only. Hand `Docs/FE/Frontend-Performance-Notes.md` to the frontend owner.

### 4.2 `final/multilang-embedder-and-test-protocol` (this branch; contains 2.1)

Investigation only. On the **Mac Studio**:

```bash
cd Pipeline
git show final/answer-quality:Pipeline/eval/data/queries_vi.jsonl > eval/data/queries_vi.jsonl
python -m tools.compare_embedders --device mps --out ../Docs/test-runs/embedder-comparison.json
```

Criteria: `Docs/BE/Multilingual-Embedder-Handoff.md` §4. After §3.8 the corpus is 1876 chunks —
re-measure the baseline model in the same run. **Expected outcome:** record the numbers; a swap is
future work behind a tokenizer parity test (handoff §5).

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
| `final/frontend-perf-notes` | main | docs | 4.1 |
| `final/multilang-embedder-and-test-protocol` | eval-integrity | investigation + this doc | 4.2 |

Merging all fifteen in this order was dry-run on 2026-09-13 after the fixes: every merge is clean
except 3.4, which resolves exactly as described there. The merged tree passes G3 (74 Python tests),
G4 (audit exit 0, 16/16), has `App/Resources/vectorstore.db` at 1876 chunks / 39 documents, and ships
`maxTokens 512`, `prefillStepSize null`, `retrievalTopK 10`, `contextTokenBudget 3000`,
`historyTokenBudget 350`, `wordsToTokensRatio null`. G1, G2 and G5 need Xcode and a device.
