# Test protocol — all `final/*` branches

_Written 2026-09-13. Lives on `final/multilang-embedder-and-test-protocol`._

This is the order to integrate and test every branch produced in the pre-presentation
optimisation pass, what each one must prove before it is kept, what to expect, and exactly
what to write down. Follow it top to bottom. **Merge one branch, test, record, decide — then
the next.** Never merge two behaviour changes between measurements: if a number moves, you
must know which branch moved it.

---

## 0. Before you start

### Hard rules

1. **Run on the Mac + iPad M5, never on a laptop.** Model downloads are multi-GB and inference
   saturates every core. The Mac Studio M3 Max is for the Python-side measurements.
2. **Pin the device for every Python ML script.** `--device cpu` or `--device mps`. An unpinned
   run grabs a CUDA card and OOMs. Every committed tool defaults to `cpu`.
3. **No Swift in these branches has ever been compiled.** It was written without Xcode. Expect a
   handful of first-compile errors; fix them on the integration branch and note each one in the
   record. Likely suspects are listed per branch.
4. **Record everything in `Docs/test-runs/`** using the template in §5 — including failures and
   reverted knobs. A kept branch with no record is an unverified branch.

### Setup, once

```bash
git fetch
git checkout -b integration/final-test main

# Python side (Mac Studio)
cd Pipeline && python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt sentence-transformers && cd ..

# Swift side — resolve and PIN the packages before anything else.
xcodebuild -resolvePackageDependencies -project MobiCureVN.xcodeproj
```

`Package.resolved` is absent from the repo even though `.gitignore:14` says it is intentionally
tracked. Commit it the moment `final/mlx-runtime-knobs` is merged (§3.6) — until then two
machines can resolve different MLX versions.

### ⚠️ Latency harness gotcha

`xcodebuild` does **not** forward ordinary environment variables into the test process on a
device. Prefix them with `TEST_RUNNER_`, which `xcodebuild` strips and passes through:

```bash
TEST_RUNNER_MOBICURE_BENCH=1 \
TEST_RUNNER_MOBICURE_BENCH_OUT="$PWD/Docs/test-runs/latency-<step>.json" \
xcodebuild test -scheme MobiCureVN -destination 'platform=iOS,name=<iPad>' \
  -only-testing:MobiCureVNTests/LatencyBenchmarkTests
```

If the test reports **skipped**, this is the first thing to check. Alternatively set the
variables in the scheme's Test action. The model must also already be **downloaded on the
device** (in-app model picker) — the harness resolves its local path through `ModelManager` and
skips with a "not downloaded" message otherwise. On a physical device the JSON cannot be written
into the repo — take it from the `.xcresult` attachment.

---

## 1. Global gates — run after EVERY merge

| Gate | Command / action | Pass |
|---|---|---|
| G1 Build | `xcodebuild build -scheme MobiCureVN` | succeeds |
| G2 Swift tests | `xcodebuild test -scheme MobiCureVN -destination …` (full suite, benchmark skipped) | 0 failures; record count |
| G3 Python tests | `cd Pipeline && python -m unittest discover -s eval/tests -t .` | 0 failures (46 once both Python branches are in) |
| G4 Privacy | `Tools/privacy_audit.sh` then `Tools/tests/test_privacy_audit.sh` | audit exit 0; suite 11/11 |
| G5 Smoke | In the app, airplane mode ON, ask the three smoke questions below | all three answer, with citations, no crash |

**Smoke questions** (use the same three every time):

- EN: `What are the signs that my surgical wound is infected?`
- VI có dấu: `Làm sao để biết vết mổ của tôi bị nhiễm trùng?`
- VI không dấu: `toi bi dau bung va khong an duoc gi`

A step that fails any gate is not kept until fixed or reverted.

---

## 2. Phase 1 — tooling and evidence (no app behaviour change)

These branches add measurement tools, tests and docs. They change nothing a patient sees, so
they go in first and together form the instrument every later step is measured with.

### 2.1 `final/eval-integrity`

**Purpose.** Fix the retrieval harness (it scored a 9-doc index against a 39-doc answer key), add
provenance to every result, add `doc_hit@k`.

**Test.**
```bash
cd Pipeline
python -m unittest discover -s eval/tests -t .
python -m eval.build_indexes
python -m eval.run_eval && python -m eval.run_eval && python -m eval.run_eval
```

| Pass criterion | Expected |
|---|---|
| unit tests | 31/31 |
| index | 1238 chunks / 39 docs |
| gold-chunk coverage | **1.000** (printed by `run_eval`; a WARN line means fail) |
| reproducibility | the 3 runs have identical metrics and identical index sha256 on the same machine |
| recall@5 | ≈ 0.249 (0.2488 measured on CPU) — tolerance ±0.01 across machines/devices |
| doc-hit@5 | ≈ 0.770 (0.7703) — tolerance ±0.01 |

**Record.** The three result JSON paths, index sha256, the four metrics, `git.dirty` value
(must be `false` if the tree was clean — this flag had a bug that is now fixed).

**Drop if.** Coverage < 1.0 or runs disagree. Nothing else in this protocol is trustworthy until
this passes.

### 2.2 `final/docs-metrics-truth`

**Purpose.** Retract the `recall@5 = 1.00` figure, mark the old A/B table provisional, make
`Docs/Eval-Integrity-Finding.md` the single source of truth.

**Test.** `git grep -n "1\.00" -- Docs` — every hit must be inside a retraction notice.

**Record.** Grep output. **Drop if.** Never — docs only.

### 2.3 `final/privacy-audit`

**Purpose.** Evidence for success criterion #1.

**Test.** G4. **Expected:** audit exit 0; the output lists Hugging Face (declared) and the
**Kaggle runtime download** in `MedicalAnchorLoader` — that finding is expected, not a failure.
Suite 11/11.

**Record.** Save the audit output to `Docs/test-runs/privacy-audit.txt`. Note whether the Kaggle
fetch has been bundled yet.

### 2.4 `final/answer-quality`

**Purpose.** Manual grounding / safety / Vietnamese review (criteria #2, #4).

**Test.**
```bash
cd Pipeline
python -m unittest eval.tests.test_answer_quality_tools
python -m tools.make_answer_sheet --n 30 --raters 2
```

| Pass criterion | Expected |
|---|---|
| unit tests | 15/15 |
| sheet | 30 rows, **18 EN + 12 VI**, identical question order in both rater files |

**Record.** Sheet paths. Do not fill them yet — that is the baseline in §2.6.

### 2.5 `final/latency-benchmark`

**Purpose.** Measure criterion #3 (<5 s).

**Test.** G1/G2 — the benchmark must report **skipped** in a normal run. Then one real run with
the `TEST_RUNNER_` variables (§0).

| Pass criterion | Expected |
|---|---|
| normal test run | benchmark **skipped** |
| opted-in run | JSON produced with `device` naming the iPad (e.g. `iPad…`, not a board id like `D84AP`) |
| skip message, if skipped | names the actual cause (opt-in variable missing, or model not downloaded) |

**Likely compile issues.** `sysctlbyname` / `UIDevice` imports; `XCTAttachment(data:uniformTypeIdentifier:)`.

**Record.** Report JSON path, device, model. **Drop if.** Never — but fix until it runs.

### 2.6 BASELINE — measure before any behaviour change

Everything below is compared against this. Do not skip it.

| Measurement | How |
|---|---|
| Retrieval | §2.1 numbers (already recorded) |
| Packing | `python -m tools.simulate_context_packing --policy old --top-k 5 --budget 600 --ratio 1.4 --device mps --out ../Docs/test-runs/packing-baseline.json` — expect **1.52 chunks sent, 22.5% zero-context, doc-hit seen 0.4450** |
| Latency | latency harness on iPad M5, default model → `latency-baseline.json` |
| Peak memory | Instruments → Allocations, one long answer, on iPad M5 |
| Answer quality | full 30-question sheet, **two raters**, one native Vietnamese speaker → `score_answer_sheet --out ../Docs/test-runs/answer-quality-baseline.json` |
| Adversarial | run `Docs/BE/Adversarial-Chat-Test-Script.md`, record pass/fail per case |

If baseline p95 time-to-final is already **> 5 s**, write that down plainly. The latency gate in
Phase 2 then becomes "must not regress more than 10% against the previous kept step".

---

## 3. Phase 2 — behaviour changes, one at a time

Order is by certainty and dependency: the confirmed bug fix first, the knobs that depend on it
next, latency work after, and the corpus change last because it invalidates retrieval
comparisons for everything before it.

Every step runs G1–G5, plus its own checks. **Quick quality check** below means: 10 questions
from the sheet (5 EN, 5 VI), one rater, scoring only `grounded` and `clinically_safe`.

### 3.1 `final/context-budget-fix` — the confirmed bug

**Purpose.** `applyContextBudget` used `break`; one oversized chunk emptied the context. Now
`continue` + partial fill, budget 600 → 2000, ratio 1.4 → 1.6, budget wired to `InferenceTuning`.

| Check | Pass criterion | Expected |
|---|---|---|
| Swift `ContextBudgetTests` | 12/12 | — |
| Packing sim `--policy new --top-k 5 --budget 2000 --ratio 1.6` | zero-context **0.0%** | 3.96 chunks sent, doc-hit seen **0.6890** (from 0.4450) |
| Knob is live | edit `contextTokenBudget` in the JSON to 800, relaunch, confirm prompt shrinks in DEBUG log, set back | budget follows the JSON |
| Latency | p95 time-to-final ≤ 5 s (or ≤ +10% if baseline was already over) | **will rise**: context 307 → ~1720 tokens |
| Quick quality | `clinically_safe` no worse; `grounded` expected **better** | more answers cite real sources |

**Record.** Packing JSON, latency JSON, the p95 delta vs baseline, quick-quality scores.

**Drop if.** Never drop the `break`→`continue` fix — it is a correctness bug. If latency fails the
gate, lower `contextTokenBudget` in the JSON (try 1200) and re-measure; record the value kept.

### 3.2 `final/retrieval-topk` — depends on 3.1

**Purpose.** `retrievalTopK` 5 → 10 as a JSON knob, budget 2000 → 3000.

| Check | Pass criterion | Expected |
|---|---|---|
| Swift `ContextBudgetTests` | 13/13 (adds the coupling test) | — |
| Packing sim `--top-k 10 --budget 3000 --ratio 1.6` | zero-context 0.0% | 6.40 chunks sent, doc-hit seen **0.7512** |
| Latency | same gate as 3.1, measured against 3.1 | context ~2850 tokens — the largest prefill of any step |
| Quick quality | `grounded` ≥ 3.1 | small gain |

**Drop if.** p95 fails the gate. This is **the branch designed to be dropped** — revert the JSON
values to `retrievalTopK: 5`, `contextTokenBudget: 2000` and record it. Do not keep topK 10 with a
smaller budget: measured, that combination gains exactly nothing.

### 3.3 `final/language-detect-fast`

**Purpose.** Plain English no longer costs a full LLM classification before the answer.

| Check | Pass criterion | Expected |
|---|---|---|
| Swift `LanguageDetectFastPathTests` | 8/8 | — |
| DEBUG log, EN smoke question | line `detect short-circuited to English (no LLM)` appears | — |
| DEBUG log, VI không dấu smoke question | that line does **NOT** appear; answer still Vietnamese | — |
| Latency, EN queries only | time-to-first-preview **lower** than previous step | one fewer generation on the critical path |
| G5 smoke | all three languages still routed correctly | — |

**Likely compile issues.** `NLLanguageRecognizer.languageHypotheses(withMaximum:)` return type.

**Drop if.** Any Vietnamese input (accented or not) is classified English.

### 3.4 `final/prompt-slimming` — has a known merge conflict

**Purpose.** Invariant system prompt 473 → 305 words (~268 fewer tokens per turn), history
budget 500 → 350.

**Conflict.** Merging after 3.2 conflicts in `App/Resources/InferenceTuning.json` and
`App/Backend/Configs/InferenceTuning.swift`, on adjacent lines only. Resolve to:

```json
"retrievalTopK": 10,          // from 3.2 (or 5 if 3.2 was dropped)
"contextTokenBudget": 3000,   // from 3.2 (or whatever 3.1/3.2 kept)
"historyTokenBudget": 350,    // from this branch
```

and the same three values in the Swift defaults. The `600` shown on this branch's side is
unchanged context from `main`, **not** an intended value — never take it.

| Check | Pass criterion | Expected |
|---|---|---|
| Swift `SystemPromptConstraintTests` | 15/15 | 14 safety rules present, ≤ 340 words |
| Existing `LanguageDriftTests`, `OutputGuardRailVietnameseTests` | pass | — |
| **Adversarial script** | **every case that passed at baseline still passes** | this is the real gate |
| Follow-up continuity | 3-turn conversation: state a fact, ask two follow-ups ("is that normal?") | model keeps the fact |
| Latency | p95 lower than previous step | prefill −~268 tokens |
| Quick quality | `clinically_safe` no worse | — |

**Drop if.** Any adversarial regression → revert the prompt text. Continuity broken → revert only
`historyTokenBudget` to 500 in the JSON and keep the prompt.

### 3.5 `final/aux-pass-gating`

**Purpose.** `ProfileUpdateExtractor` no longer runs a generation on turns that state nothing
about the patient.

| Check | Pass criterion | Expected |
|---|---|---|
| Swift `AuxPassGatingTests` | 8/8 | includes a test pinning that "What is a stoma?" DOES run the pass — intended |
| DEBUG log after a plain question | `6-7 · Post-answer passes … both skipped` | — |
| Profile proposal still works | say "I am 62 years old and allergic to penicillin" | confirmation card appears |
| Back-to-back latency | send 5 questions without waiting; compare turn 2-5 time-to-first-preview vs previous step | lower — this only shows on the NEXT turn |

**Drop if.** A genuine self-disclosure no longer produces a proposal card.

### 3.6 `final/mlx-runtime-knobs`

**Purpose.** Pin MLX to `upToNextMinorVersion`, wire `prefillStepSize` / `kvBits` / `maxKVSize`,
`maxTokens` 1024 → 512.

**First:** re-resolve packages and **commit `Package.resolved`**. Then follow
`Docs/BE/mlxApiVerification.md` to confirm the five property names on `GenerateParameters`.

| Check | Pass criterion | Expected |
|---|---|---|
| G1 build | compiles against the pinned version | a moved property name fails loudly here — fix the name, update `InferenceTuning` to match |
| Truncation | answer all 30 sheet questions; count answers cut mid-sentence | **≤ 1 of 30** at `maxTokens: 512` |
| Peak memory | Instruments, same long answer as baseline | lower or equal (`prefillStepSize: 512`) |
| Latency | p95 time-to-final lower than previous step | worst-case decode halved |

**Optional kvBits sweep** (only if a device is memory-constrained): `kvBits` null → 8 → 4 via the
JSON, recording latency + peak memory + full quality sheet for each. Keep 8-bit only if quality is
unchanged; 4-bit only if 8-bit does not fit.

**Drop if.** More than 1/30 answers truncated → set `maxTokens` back toward 768 in the JSON, keep
the rest.

### 3.7 `final/prefix-kv-cache` — depends on 3.6, groundwork only

**Purpose.** Split the system prompt into `stablePrefix` + `volatileSuffix` and prove the prefix is
byte-stable. **Runtime cache reuse is NOT implemented** (see `Docs/BE/Prefix-KV-Cache.md`).

| Check | Pass criterion | Expected |
|---|---|---|
| Swift `PrefixStabilityTests` | 10/10 | — |
| Latency | **no meaningful change** vs 3.6 (±5%) | none — nothing is cached yet |
| Quick quality | no worse | the halves are joined with one extra newline, so temperature-0 output may differ trivially |

**Drop if.** Quality regresses. Do not expect or claim a latency gain from this branch.

### 3.8 `final/chunk-splitting` — last, invalidates retrieval comparisons

**Purpose.** Split chunks over the embedder window. 1238 → 2108 chunks, max 482 tokens.

The chunk JSON is already regenerated on the branch, but chunk IDs have shifted, so:

```bash
cd Pipeline
python -m eval.build_indexes
python -m tools.remap_qrels --apply          # remap the golden set to the new IDs
python -m eval.run_eval
python -m tools.simulate_context_packing --policy new --top-k 10 --budget 3000 --ratio 1.6 --device mps
./run_pipeline.sh --force && cp vectorstore.db ../App/Resources/vectorstore.db
```

| Check | Pass criterion | Expected |
|---|---|---|
| Split ceiling | `max(token_count)` ≤ 512 across `data/neural_chunks` | 482 |
| Coverage after remap | ≥ 0.95 | remap may drop gold chunks with no clean equivalent — record how many |
| doc-hit@5 | ≥ 0.7703 − 0.01 | unknown — more, smaller chunks can go either way |
| Packing sim | zero-context 0.0% | more chunks fit per budget |
| App index | `App/Resources/vectorstore.db` rebuilt and copied; G5 citations still render | — |
| Quick quality | `grounded` ≥ previous step | — |

**Drop if.** Coverage < 0.95 or doc-hit regresses beyond tolerance. Revert the branch and restore
the previous `App/Resources/vectorstore.db`.

---

## 4. Phase 3 — documentation and investigation

### 4.1 `final/frontend-perf-notes`

Docs only. No test. Hand `Docs/FE/Frontend-Performance-Notes.md` to the frontend owner.

### 4.2 `final/multilang-embedder-and-test-protocol` (this branch)

Investigation only; no app behaviour change. Run on the **Mac Studio**:

```bash
cd Pipeline
git show final/answer-quality:Pipeline/eval/data/queries_vi.jsonl > eval/data/queries_vi.jsonl
python -m tools.compare_embedders --device mps --out ../Docs/test-runs/embedder-comparison.json
```

Pass / decision criteria are in `Docs/BE/Multilingual-Embedder-Handoff.md` §4. **Expected
outcome: record the numbers, do not swap the embedder before the presentation** — the Swift
tokenizer blocker (§5 of the handoff) makes it future work regardless of the result.

---

## 5. Defects already fixed while writing this protocol

No Swift here has been compiled, so every Swift test was cross-checked by hand — mirroring the
production logic in Python where possible. That review found and fixed five defects **before**
anyone ran them. Listed so a tester is not surprised by the extra commits on these branches:

| Branch | Defect | Would have looked like |
|---|---|---|
| `final/latency-benchmark` | passed a Hugging Face repo id to `LLMService(modelPath:)`, which only checks `fileExists(atPath:)` | benchmark **always skipped**, no number ever produced |
| `final/latency-benchmark` | documented `MOBICURE_BENCH=1 xcodebuild …` without the `TEST_RUNNER_` prefix | benchmark **always skipped** on device |
| `final/context-budget-fix` (+ `retrieval-topk`) | a test expected small chunks behind an oversized one to be kept even when the partial-fill rule takes precedence | `ContextBudgetTests` **failing** on first run; the measured 0.4450 → 0.6890 was always computed against the real behaviour |
| `final/aux-pass-gating` | two tests asserted "What is a stoma?" / "Hậu môn nhân tạo là gì?" skip the gate; the cue list deliberately matches them | `AuxPassGatingTests` **failing** on first run |
| `final/prefix-kv-cache` | the test built the orchestrator from AppConfig's SwiftData singletons | possible test-host crash or slow, stateful tests |

If a test in these files still fails on first compile, treat it the same way: check whether the
**test** encodes a wrong expectation before changing production code.

---

## 6. Record template

One file per step: `Docs/test-runs/NN-<branch>.md`.

```markdown
# NN — final/<branch>

- Date / tester:
- Integration commit (`git rev-parse HEAD`):
- Devices: iPad model id + iOS | Mac model + macOS | RAM
- Model under test (ModelCatalog):
- InferenceTuning.json values in effect (paste the `prompt` and `generation` blocks):

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

## 7. Final checks — the numbers for the presentation

After the last kept step:

1. Full G1–G5.
2. Latency harness on **iPad M5 and Mac Studio**, cold start reported separately, p95 stated.
3. `python -m eval.run_eval` ×3 — identical.
4. Full 30-question sheet, two raters, per-language split — compare against the baseline in §2.6.
5. Adversarial script, full.
6. Airplane-mode demo video: voice → retrieval → cited answer → citation card → TTS.

Build one summary table — baseline vs final — for: p95 time-to-final, cold start, peak memory,
doc-hit@5, grounding rate seen by the model, answer-quality scores (EN / VI), adversarial pass
rate, privacy audit result. **Every number on a slide must trace to a file in `Docs/test-runs/`.**

---

## Appendix — branch map

| Branch | Base | Kind | Phase |
|---|---|---|---|
| `final/eval-integrity` | main | tooling | 2.1 |
| `final/docs-metrics-truth` | main | docs | 2.2 |
| `final/privacy-audit` | main | tooling | 2.3 |
| `final/answer-quality` | main | tooling | 2.4 |
| `final/latency-benchmark` | main | tooling | 2.5 |
| `final/context-budget-fix` | main | **bug fix** | 3.1 |
| `final/retrieval-topk` | context-budget-fix | knob | 3.2 |
| `final/language-detect-fast` | main | latency | 3.3 |
| `final/prompt-slimming` | main | latency (conflict) | 3.4 |
| `final/aux-pass-gating` | main | latency | 3.5 |
| `final/mlx-runtime-knobs` | main | latency / memory | 3.6 |
| `final/prefix-kv-cache` | mlx-runtime-knobs | groundwork | 3.7 |
| `final/chunk-splitting` | main | corpus | 3.8 |
| `final/frontend-perf-notes` | main | docs | 4.1 |
| `final/multilang-embedder-and-test-protocol` | eval-integrity | investigation + this doc | 4.2 |

Merging all fifteen in this order was dry-run on 2026-09-13, and again after the §5 fixes: every merge is clean except 3.4, whose
conflict resolves exactly as described there, leaving `retrievalTopK 10`, `contextTokenBudget
3000`, `historyTokenBudget 350`, `maxTokens 512`, `prefillStepSize 512`.
