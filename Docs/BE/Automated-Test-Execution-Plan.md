# Automated test execution plan — feed this to Claude Code

Source of truth: `Docs/Test-Protocol.md`. This file translates it into an ordered, mechanical
checklist for an agent running on the Mac with Xcode and a connected iPad (physically plugged in,
already trusted/paired). The teammate has already run the Python/tooling side on Mac — this plan
assumes that work is done and focuses on what is still unverified: Swift tests, builds, and
anything that requires a real device.

**Ground rule for the executing agent:** never mark a check PASS without having actually run the
command and read its output. If a step needs something only a human can do (plugging in a device,
installing a dictation language, watching a demo), stop and ask rather than guessing or skipping
silently.

---

## 0. Setup — do this first, once

```bash
git fetch
git status   # confirm clean tree before branching
git checkout -b integration/final-test main
cd Pipeline && python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt coremltools && cd ..
xcodebuild -resolvePackageDependencies -project MobiCureVN.xcodeproj
xcrun xctrace list devices   # confirm the iPad appears; record its exact device name/id
```

Ask the user to confirm the iPad's exact `-destination` string before running any device test —
do not guess it.

Create `Docs/test-runs/` if it doesn't exist. Every step below produces one record file there,
named `NN-<branch>.md`, using the template in `Docs/Test-Protocol.md` §5. Do not batch records at
the end — write each one immediately after that step's checks finish.

---

## 1. Merge sequence

Merge branches **one at a time**, in this exact order (from the Appendix of Test-Protocol.md).
After **every** merge, run the global gates (§2 below) before moving to the next branch. Do not
merge two branches without running gates in between.

```
final/eval-integrity
final/docs-metrics-truth
final/privacy-audit
final/answer-quality
final/latency-benchmark
final/context-budget-fix
final/retrieval-topk
final/language-detect-fast
final/prompt-slimming          # <- known merge conflict, see §1a below
final/aux-pass-gating
final/mlx-runtime-knobs        # <- resolve Package.resolved gitignore, see §1b below
final/prefix-kv-cache
final/chunk-splitting
final/docs-fe-perf
final/multilang-embedder-and-test-protocol
```

Note: Test-Protocol.md §4.1 calls this branch `final/frontend-perf-notes` in its header text, but
its own Appendix table and §7 for-loop both say `final/docs-fe-perf` — confirmed on `origin` that
only `final/docs-fe-perf` actually exists. Use that name; the other is a stale name left in the
doc's prose.

Command per branch: `git merge --no-edit origin/<branch>`

### 1a. `final/prompt-slimming` conflict

Conflicts in `App/Backend/Configs/InferenceTuning.swift` and
`App/Resources/InferenceTuning.json`. Resolve to exactly:

```
retrievalTopK: 10
contextTokenBudget: 3000
historyTokenBudget: 350
wordsToTokensRatio: nil / null
```

Never take the `600` value — it's `main`'s stale value, not intended. After resolving, run
`InferenceTuningResolutionTests` — it fails if the Swift defaults and the JSON disagree.

### 1b. `final/mlx-runtime-knobs` — Package.resolved

```bash
xcodebuild -resolvePackageDependencies -project MobiCureVN.xcodeproj
git check-ignore -v MobiCureVN.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
```
Must print nothing (not ignored). Then `git add` and commit it.

---

## 2. Global gates — run after every merge in §1

Test-Protocol.md only specifies one G1 build and one G2 device test run. The simulator row below
is an addition of mine, not in the protocol — a cheap sanity check to catch compile errors before
burning time on the physical device. Don't treat a simulator pass as satisfying G2; the iPad row
is the one the protocol actually requires.

| Gate | Command | Pass |
|---|---|---|
| G1 Build | `xcodebuild build -scheme MobiCureVN` | BUILD SUCCEEDED |
| G2 Swift tests (simulator — my addition, fast pre-check only) | `xcodebuild test -scheme MobiCureVN -destination 'platform=iOS Simulator,name=iPhone 17 Pro'` | 0 failures — record pass count |
| G2 Swift tests (iPad, physical — this is the protocol's actual G2) | same, with `-destination 'platform=iOS,name=<iPad name from §0>'` | 0 failures — record pass count |
| G3 Python tests | `cd Pipeline && python -m unittest discover -s eval/tests -t .` | 0 failures (74 once all Phase 1–3 merged) |
| G4 Privacy | `Tools/privacy_audit.sh && Tools/tests/test_privacy_audit.sh` | audit exit 0; suite 16/16 |
| G5 Smoke (device, airplane mode ON) | manually run the 3 fixed questions below through the app on the iPad | all 3 answer, with citations, no crash |

**Smoke questions (always these three, never substitute):**
- EN: `What are the signs that my surgical wound is infected?`
- VI có dấu: `Làm sao để biết vết mổ của tôi bị nhiễm trùng?`
- VI không dấu: `toi bi dau bung va khong an duoc gi`

G5 needs a human to physically toggle airplane mode and read the screen — flag this step to the
user rather than assuming it passed.

If any gate fails: **do not proceed to the next branch.** Fix or revert, record the failure and
the fix in that branch's record file, then re-run gates before continuing.

---

## 2a. BASELINE — measure once, after Phase 1, before any Phase 2 branch

Per Test-Protocol.md §2.6: after `final/eval-integrity` through `final/latency-benchmark` are
merged and gated, and **before** merging `final/context-budget-fix`, take this snapshot so every
Phase 2 branch has something real to diff against:

| Measurement | How | Expected |
|---|---|---|
| Retrieval | already covered by §2.1's `run_eval` numbers | see eval-integrity record |
| Packing | `python -m tools.simulate_context_packing --policy old --top-k 5 --budget 600 --ratio 1.4 --device cpu --out ../Docs/test-runs/packing-baseline.json` | ~1.52 chunks, ~22.5% zero-ctx, doc-hit seen ~0.445 |
| Latency | harness on iPad M5 → `latency-baseline.json` | record raw p50/p95 |
| Peak memory | Instruments → Allocations, one long answer | record peak MB — flag to user, manual step |
| Answer quality | 30-question sheet, two raters → `answer-quality-baseline.json` | flag to user — needs raters |
| Adversarial | full run of `Docs/BE/Adversarial-Chat-Test-Script.md` | all pass |

If baseline p95 time-to-final is already > 5s, record that plainly — the Phase 2 latency gate then
becomes "no more than 10% regression vs. the previous kept step" instead of an absolute 5s ceiling.

---

## 3. Per-branch device checks

Every Phase 2 branch (§3.1–§3.8 below) also gets a **Quick quality check**: 10 questions from the
sheet (5 EN, 5 VI), one rater, scoring only `grounded` and `clinically_safe` — flag this to the
user, it needs a human rater. This applies to every row in the table below even where not spelled
out per-branch.

After a branch's gates pass, also run its branch-specific checks from Test-Protocol.md. These are
the ones currently marked `⏭ SKIPPED (needs Xcode)` / `(needs device)` in the doc — they are the
actual point of this testing pass.

| Branch | Additional checks (run on iPad unless noted) |
|---|---|
| `final/eval-integrity` | `QueryEmbedderParityTests` (3/3, cosine ≥ 0.999); DEBUG log on launch has no "vector search disabled" line |
| `final/privacy-audit` | Voice input in Vietnamese, airplane mode on. If no on-device VI dictation is installed, install it first and record which version. |
| `final/latency-benchmark` | Opted-in latency run (see §4) |
| `final/context-budget-fix` | `ContextBudgetTests` (19/19), `InferenceTuningResolutionTests` (10/10); stale-seed log says "replacing it" on first launch; edit `Documents/InferenceTuning.json` via Devices and Simulators → confirm prompt shrinks; no citation card names a doc absent from context; latency p95 ≤ 5s |
| `final/retrieval-topk` | `ContextBudgetTests` (20/20, pins topK 10/budget 3000); latency ≤ +10% vs previous kept step |
| `final/language-detect-fast` | `LanguageDetectFastPathTests` (11/11); DEBUG log on EN question shows "detect short-circuited to English (no LLM)"; that line must NOT appear for VI không dấu input; time-to-first-preview lower than previous step |
| `final/prompt-slimming` | `SystemPromptConstraintTests` (16/16 — note: known line-wrap fix already applied at `MedicalChatOrchestrator.swift:630`, verify it's still there); `LanguageDriftTests`, `OutputGuardRailVietnameseTests`; **full adversarial script** (`Docs/BE/Adversarial-Chat-Test-Script.md`) — every baseline case must pass; no disclaimer on "thanks"/small talk; a stated fact survives 3 turns; latency lower than previous step |
| `final/aux-pass-gating` | `AuxPassGatingTests` (10/10); DEBUG log on a plain question shows both "Fact extraction … skipped" and "Profile update … skipped"; typing "I am 62 and allergic to penicillin" produces a profile proposal card; turns 2-5 latency faster than previous step |
| `final/mlx-runtime-knobs` | `GenerationCompletionTests` (5/5); count truncated answers over 18 EN + 12 VI questions — must be ≤ 1 per language; latency lower than previous step |
| `final/prefix-kv-cache` | `PrefixStabilityTests` (11/11, byte-identical prefix across turns); latency within ±5% of previous step (no gain claimed here) |
| `final/chunk-splitting` | Run `cd Pipeline && python -m eval.build_indexes` to rebuild the neural index from the 1876-chunk corpus (this was left undone as of 2026-09-14), then re-run packing sim `--top-k 10 --budget 3000 --ratio 1.75` — expect doc-hit seen ≥ 0.8034; G5 citations render correctly from rebuilt `App/Resources/vectorstore.db` |

---

## 4. Latency benchmark harness

Run this after every branch in §3 that claims a latency effect (context-budget-fix,
retrieval-topk, language-detect-fast, prompt-slimming, mlx-runtime-knobs, prefix-kv-cache), on
**both** the iPad and the Mac Studio:

```bash
TEST_RUNNER_MOBICURE_BENCH=1 \
TEST_RUNNER_MOBICURE_BENCH_OUT="$PWD/Docs/test-runs/latency-<branch>-ipad.json" \
xcodebuild test -scheme MobiCureVN -destination 'platform=iOS,name=<iPad>' \
  -only-testing:MobiCureVNTests/LatencyBenchmarkTests
```

Mac Studio destination: `'platform=macOS,arch=arm64,variant=Designed for iPad'` (change the
`_OUT` filename to `-mac.json`). 30 samples per run. Compare p50/p95 against the previous kept
step's numbers, not against baseline every time.

---

## 5. Memory check

Test-Protocol.md calls for this once, at baseline (§2a above). Re-running it after
`final/mlx-runtime-knobs` is my addition, not protocol-required — that branch touches generation
knobs that plausibly affect memory, so it seemed worth a second data point, but don't present it
as a protocol gate. Either way: open Instruments → Allocations, attached to the app on the iPad,
ask a long question, capture peak memory. This is a manual Instruments session — flag it to the
user rather than attempting to script it.

---

## 6. Phase 4 — `final0.1-*` branches (run only after §1-5 all KEEP)

These were written with **no Xcode and no device access at all** — assume nothing about them
compiles. Build the base:

```bash
git checkout -b final0.1-base main
for b in eval-integrity docs-metrics-truth privacy-audit answer-quality latency-benchmark \
         context-budget-fix retrieval-topk language-detect-fast prompt-slimming \
         aux-pass-gating mlx-runtime-knobs prefix-kv-cache chunk-splitting docs-fe-perf \
         multilang-embedder-and-test-protocol; do
  git merge --no-edit "final/$b"
done
# resolve final/prompt-slimming exactly as in §1a
```

Then merge, in any order (all touch disjoint files except the one dependency noted):
```
final0.1-contextual-header
final0.1-model-catalog
final0.1-reranker
final0.1-fm-aux-routing
final0.1-qrels-pooling
final0.1-dwq                  # must come before lora-distill
final0.1-lora-distill         # imports from quant module added by dwq
```

Per branch, run:

| Gate | Command | Pass |
|---|---|---|
| P4.1 Python tests | `cd Pipeline && python -m unittest discover -s eval/tests -t .` | 0 failures (119 with all seven merged) |
| P4.2 Privacy | `Tools/privacy_audit.sh` | exit 0, VERDICT: consistent |
| P4.3 Eval number | `cd Pipeline && python -m eval.run_eval` | `neural_contextual` doc-hit@5 reproduces 0.8038 within noise |
| P4.4 Build (first time in Xcode — expect real errors) | `xcodebuild build -scheme MobiCureVN` | fix and record every compile error, per branch |

After P4.4 passes for all seven, run full G2 (device) and G5 (smoke) — these branches have never
had either run.

**Do not merge** `final0.1-embedder-candidates` — it has an uncommitted, incomplete local patch
(see `Docs/BE/Multilingual-Embedder-Handoff.md` §9).

---

## 7. Final numbers (only once everything above is KEEP)

1. Full G1–G5 including `QueryEmbedderParityTests`.
2. Latency harness on iPad M5 and Mac Studio, cold start measured separately, p95 over 30 samples.
3. `python -m eval.run_eval` ×3 — must be identical, `dirty: false`.
4. Full adversarial script (`Docs/BE/Adversarial-Chat-Test-Script.md`), every case.
5. Airplane-mode demo: voice (on-device dictation) → retrieval → cited answer → citation card →
   TTS. This is a human-watched demo, not scriptable — flag it.
6. 30-question answer-quality sheet with two human raters — **flag to the user**, this cannot be
   done by the agent alone.

Produce one summary table: p95 time-to-final, cold start, peak memory, doc-hit@5, doc-hit seen,
answer quality (per language + kappa), adversarial pass rate, privacy audit — baseline vs final.
Every number must trace to a file in `Docs/test-runs/`.

---

## What the agent must escalate rather than guess

- Exact iPad destination string / device availability
- Any gate failure that isn't a straightforward, obviously-safe fix
- G5 smoke test and airplane-mode demo (need a human toggling airplane mode and reading output)
- Dictation language installation
- Instruments memory profiling session
- The two-rater answer-quality sheet
- Any merge conflict outside the one documented in §1a
