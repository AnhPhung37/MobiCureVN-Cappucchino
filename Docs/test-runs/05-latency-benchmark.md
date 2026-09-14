# 05 — final/latency-benchmark

- Date / tester: 2026-09-14 / Claude Code (agent-executed)
- Integration commit at merge: merge commit onto `e3a6328` (clean, no conflicts)
- Devices: simulator iPhone 17 Pro (26.4.1) for the normal-run check; physical iPad opt-in run
  not attempted (needs device access + a long dedicated run — escalated)

## Gates

| G1 build | G2 Swift (sim, `-only-testing:MobiCureVNTests`, non-parallel) | G3 Python | G4 privacy | G5 smoke |
|---|---|---|---|---|
| ✅ BUILD SUCCEEDED | 341 tests, 1 skipped, 4 failed | not re-run (unaffected) | not re-run (unaffected) | N/A |

The 4 failures are the **exact same 4** pre-existing guardrail failures documented in
`01-eval-integrity.md` (`InputGuardRailTests` ×3, `OutputGuardRailTests.testBlocksLowConfidence
MedicalAdvice`) — same file, same line, same message, unrelated to this branch.

## Compile fixes needed

None. `LatencyBenchmarkTests.swift` compiled cleanly first try — no `ProcessInfo.isiOSAppOnMac` or
`XCTAttachment(data:uniformTypeIdentifier:)` API issues (the doc's "likely suspects" list didn't
materialize).

## Note on this run: simulator infra flake, not a branch issue

First two attempts at this branch's G2 failed with `Simulator device failed to launch … denied by
service delegate (SBMainWorkspace) for reason: Busy ("Application failed preflight checks")` —
**zero tests even started** on both. `xcrun simctl shutdown all` + explicit reboot of the target
simulator fixed it on the third attempt. Recorded here since it's a real operational finding for
running this campaign on a laptop rather than the assumed Mac Studio: back-to-back heavy
`xcodebuild test` invocations can starve CoreSimulator services. Fix if it recurs: shut down and
reboot the simulator, not a code change.

## Branch-specific checks

| Check | Pass criterion | Result | Pass? |
|---|---|---|---|
| Normal G2 run | benchmark reports **SKIPPED** | `testEndToEndLatencyMeetsBudget` : "Test skipped - Latency benchmark is opt-in: set MOBICURE_BENCH=1 (via xcodebuild: TEST_RUNNER_MOBICURE_BENCH=1)" | ✅ |
| Opted-in run (device, 30 samples) | `device` = iPad or Mac | not run — needs physical device access (pending permission grant) | ⏭ escalated |

## Escalated to the user

Opted-in latency run needs the physical iPad and produces the actual latency numbers used
throughout the rest of this campaign's "Numbers" tables. Deferred until device access is
available; every later branch's "Numbers" row will show `⏭ pending device` for latency until this
is run once, after which each subsequent branch's own opt-in run can diff against it.

## Numbers (vs previous kept step)

No behavior change (opt-in scaffolding only). G3 unchanged (not re-run; nothing in this branch
touches Python).

## Decision

**KEEP.** Compiles clean, self-skips correctly in a normal run, no new test failures introduced.
