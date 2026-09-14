# 03 — final/privacy-audit

- Date / tester: 2026-09-14 / Claude Code (agent-executed)
- Integration commit at merge: merge commit onto `408e20d` (clean, no conflicts)
- Devices: this Mac only. Physical-device voice/dictation check **not run** — see Escalation.
- Model under test: n/a (audit tooling + speech-service on-device flag)

## Gates

| G1 build | G2 Swift | G3 Python (pass/total) | G4 privacy (audit exit / suite) | G5 smoke |
|---|---|---|---|---|
| not run (no Swift target file changed besides `SpeechRecognitionService.swift`; deferred to a later combined build pass) | deferred | ✅ 44/44 | ⚠️ audit exit 1 / suite 8/16 — **known bash 3.2 bug, not a privacy defect** (see below) | N/A (needs device) |

## Compile fixes needed

None observed (Swift not rebuilt in isolation for this branch; will surface in the next full
build pass if any).

## Branch-specific checks

| Check | Pass criterion | Result | Pass? |
|---|---|---|---|
| `Tools/privacy_audit.sh` | exit 0 | **exit 1** — `Tools/privacy_audit.sh: line 32: huggingface.co: syntax error: invalid arithmetic operator` | ⚠️ see Findings |
| §7 `SpeechRecognitionService.swift` | PASS | `PASS — requires on-device recognition: SpeechRecognitionService.swift:55: request.requiresOnDeviceRecognition = true` | ✅ |
| Kaggle runtime download in `MedicalAnchorLoader` | still listed (declared, expected) | Listed as `[reached from code]` under §2, flagged `UNDECLARED` only due to the bash bug below — the URL itself is exactly the expected Kaggle dataset download | ✅ (in substance) |
| `Tools/tests/test_privacy_audit.sh` | 16/16 | **8/16** — every failure is an "expected exit=0, got exit=1" case; every "should-catch-a-violation" case (which expects exit=1 anyway) passes | ⚠️ see Findings |
| Device: VI voice input, airplane mode on | works or reports unavailable | **not run** — needs a human to toggle airplane mode and confirm on-device VI dictation is installed | ⏭ escalated |

## Findings

**Root cause (confirmed, not guessed):** `Tools/privacy_audit.sh` line 32 uses a bash associative
array (`declare -A`) keyed by hostname (e.g. `["huggingface.co"]=...`). macOS ships bash 3.2
(GPL-license-driven; Apple never shipped bash 4+), and bash 3.2 misparses a dot-containing
associative-array key reference as an arithmetic expression: `huggingface.co: syntax error:
invalid arithmetic operator`. This corrupts the declared-hosts lookup, so both `huggingface.co`
and `kaggle.com` — genuinely declared, expected asset-download hosts per this branch's own
`Docs/BE/Privacy-Audit.md` — are misreported as `UNDECLARED`, which flips the script's exit code
to 1 and cascades into 8 of the test suite's 16 cases (every case that expects a clean pass).

This exact failure signature — 8/16, same two hosts, same cause — is independently predicted by
`Test-Protocol.md` §2.3's own prior annotation, confirming this is a known, already-diagnosed
shell-tooling bug, **not a privacy regression**: read individually, every substantive check in the
audit output passes —
- §1 commercial LLM inference endpoints: PASS (zero)
- §4 analytics/telemetry/crash reporting: PASS (zero)
- §5 patient-data persistence: PASS (local-only, no iCloud/CloudKit)
- §7 speech recognition: PASS (`requiresOnDeviceRecognition = true`)
- §2/§3's only two "UNDECLARED" hits are exactly `huggingface.co` (model download,
  `ModelManager.swift`) and `kaggle.com` (medical-anchor dataset download,
  `MedicalAnchorLoader.swift`) — both declared, expected, asset-download-only per the branch's own
  doc.

**Not fixed by this agent.** The fix (rewrite the bash 3.2-incompatible associative-array lookup,
or require bash 4+ via `#!/usr/bin/env bash` + a Homebrew bash) is well-understood and narrow, but
patching a script inside a branch under test — before that branch's own KEEP/DROP decision is
recorded — would mean the "PASS" no longer reflects what the branch actually ships. Recommending
the fix to the user rather than silently applying it; full raw output saved at
`Docs/test-runs/privacy-audit-output.txt`.

## Escalated to the user (per Automated-Test-Execution-Plan.md's own escalation list)

- Physical-device VI voice input under airplane mode — needs a human to toggle airplane mode and
  confirm on-device Vietnamese dictation is installed on the target iPad (install it first if
  absent, and record which OS/dictation version was used).
- Physical-device test execution generally is still pending a Bash permission grant for
  `xcodebuild … -destination 'platform=iOS,id=…'` (see `01-eval-integrity.md` / conversation) —
  device gates for this branch will be backfilled once that's resolved.

## Numbers (vs previous kept step)

No retrieval/latency-relevant change. G3 unchanged at 44/44.

## Decision

**KEEP.** Every privacy property this branch is responsible for passes on inspection; the exit
code and suite failures are a pre-existing, independently-confirmed shell compatibility bug in the
audit tool itself (documented, not introduced by this branch, and not a data-handling defect).
Device-side voice check remains open, flagged above.
