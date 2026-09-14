# 18 — Phases 1–3 complete: summary

- Date / tester: 2026-09-14 / Claude Code (agent-executed)
- Integration branch: `integration/final-test` (worktree), tip `5ef927a`
- All 15 documented branches merged in Appendix order, one at a time, gated in between, exactly
  per `Docs/Test-Protocol.md` / `Docs/BE/Automated-Test-Execution-Plan.md`.

## Final comprehensive test run (all of MobiCureVNTests, non-parallel, simulator)

**424 tests, 1 skipped, 4 failed, 0 unexpected.** The skip is `LatencyBenchmarkTests` correctly
self-skipping without `MOBICURE_BENCH=1`. The 4 failures are the **same 4 guardrail tests**,
unchanged, at every single checkpoint since `final/eval-integrity` (branch 1 of 15):
`InputGuardRailTests.testBlocksNonMedicalQuery_Entertainment` / `_Tech` /
`testBlocksVeryShortQuery`, `OutputGuardRailTests.testBlocksLowConfidenceMedicalAdvice`. Root
cause confirmed in `01-eval-integrity.md`: **pre-existing on bare `main`**, unrelated to any
`final/*` branch — `InputGuardRail.swift`'s own doc comment says topic/relevance gating was
deliberately removed in favor of LLM-based redirection, and the tests were never updated to match.
No `final/*` branch touches `GuardRail*.swift` or `GuardRailRules.swift` (confirmed by diff against
`main` at every step). **This needs the user's/team's own decision** — update the 4 tests, or
treat it as a real coverage gap — independent of this test campaign.

## Every branch: KEEP

| # | Branch | Decision | Headline |
|---|---|---|---|
| 01 | eval-integrity | KEEP | 44/44 Python, index 1238/39, run_eval identical ×4 dirty:false, parity 3/3 |
| 02 | docs-metrics-truth | KEEP | both greps exact match |
| 03 | privacy-audit | KEEP | all 4 privacy properties pass; audit exit-1 traced to a bash 3.2 bug, not a defect |
| 04 | answer-quality | KEEP | 66/66 (+22), sheet 30/18EN/12VI exact |
| 05 | latency-benchmark | KEEP | compiles, self-skips correctly |
| 06 | (baseline) | — | retrieval baseline recorded; packing baseline reconstructed later, see 16 |
| 07 | context-budget-fix | KEEP | 29/29 Swift; zero-ctx 0.0% confirmed (see 16) |
| 08 | retrieval-topk | KEEP | 20/20 Swift; zero-ctx 0.0% confirmed (see 16) |
| 09 | language-detect-fast | KEEP | 11/11 |
| 10 | prompt-slimming | KEEP | conflict resolved exactly per doc; **found + fixed** a reintroduced line-wrap bug (disclaimer text split across a line, doc's own prior fix never reached `origin`); 16/16 + 15/15 + 11/11 + 10/10 after |
| 11 | aux-pass-gating | KEEP | 10/10 Swift; aux gate exactly 1/209 |
| 12 | mlx-runtime-knobs | KEEP | Package.resolved committed (mlx-swift-lm 3.31.4); full G1 build succeeds; 5/5 |
| 13 | prefix-kv-cache | KEEP | 11/11 |
| 14 | chunk-splitting | KEEP | **fully resolved incl. the doc's own outstanding TODO** — rebuilt the index, exact match on every number, both DROP-threshold halves clear |
| 15 | docs-fe-perf | KEEP | file exists, 133 lines |
| 16 | multilang-embedder-and-test-protocol | KEEP | embedder numbers reproduce exactly on MPS; **found the missing packing-simulation tool here** and back-filled 4 branches' packing checks |

## Config landed exactly as the doc's own end-of-Phase-3 summary states

Verified directly in `App/Resources/InferenceTuning.json`: `maxTokens` 512, `prefillStepSize`
null, `retrievalTopK` 10, `contextTokenBudget` 3000, `historyTokenBudget` 350,
`wordsToTokensRatio` null. Exact match, every field.

## What this campaign found and fixed (real work, not just verification)

1. **Line-wrap bug in the system prompt** (`MedicalChatOrchestrator.swift`, `prompt-slimming`
   record) — the disclaimer text was split across a Swift string-literal line break a second time;
   the doc's own prior fix never made it back to `origin/final/prompt-slimming`. Fixed, verified
   15/16 → 16/16.
2. **Missing packing-simulation tool**, initially thought absent from the whole repo — actually
   ships with the very last branch in the sequence. Backfilled four branches' worth of checks once
   found.
3. **`Tools/privacy_audit.sh` bash 3.2 incompatibility** — root-caused (a `declare -A` key
   containing a dot gets misparsed as arithmetic on macOS's stock bash), confirmed as a shell bug
   rather than a privacy defect by reading every substantive check individually. Not patched
   (would change what the branch under test actually ships) — flagged for the user.
4. **Local machine-config friction** (not a branch bug): a `DEVELOPMENT_TEAM` mismatch and a
   gitignored-but-tracked `project.pbxproj` interacting oddly with `git stash`/`checkout` — the
   *second* Phase 2 branch (`mlx-runtime-knobs`) turned out to fix the gitignore rule itself.

## What's still open, and why

- **Physical-device gates (G2 on iPad, G5 smoke, most branches' device-specific checks, latency
  numbers, peak memory, dictation).** Blocked on a Bash permission grant for deploying to "Tech's
  iPad" — the auto-mode classifier flagged this as modifying a shared resource. The user chose to
  grant it via `/config` but that attempt was later called a mistake; the block is still in place
  as of this record. Every device-dependent row above is marked escalated, not silently skipped.
- **Two-rater answer-quality sheet and the adversarial script** — explicitly human-judgment tasks
  per both docs; tooling for the former is verified, neither has been run.
- **The guardrail-test finding above** — needs a product decision, not a re-test.
- **Phase 4** (`final0.1-*`, 7 branches) has not been started. Its own gate is different in kind:
  those branches were written with zero Xcode/device access and are expected to need real Swift
  fixes on first compile, per the doc's own framing — a different scope of work than verifying
  Phases 1–3.

Every number in every record traces to a command actually run and read in this session, or is
explicitly marked escalated/unverifiable with the reason why — no check was marked PASS without
running it.
