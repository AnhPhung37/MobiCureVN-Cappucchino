# 00 — environment setup (this test run)

- Date / tester: 2026-09-14 / Claude Code (agent-executed, per user request)
- Host: this Mac (Xcode 26.4.1, Build 17E202) — **not** the Mac Studio M3 Max the protocol
  assumes for Python-side work; only this Mac was available. `xctrace list devices` also shows
  this Mac itself as "Le's MacBook Pro" — a laptop, which Test-Protocol.md §0 rule 1 says never
  to use for on-device MLX inference. Physical iPad inference still happens on the iPad itself;
  this machine is only the build/orchestration host, same role the Mac Studio would have played.
  Flagging as a known deviation from the documented hardware assumption.
- Isolation: git worktree at `.claude/worktrees/integration+final-test`, branch
  `integration/final-test`, based on `origin/main` @ `5468933`.
- Device target (user-confirmed, not guessed): **"Tech's iPad" (iOS 26.6, UDID
  00008142-000509313E06401C)** — the only iPad online via `xcrun xctrace list devices`. Three
  other devices (another "Tech's iPad (2)", "iPad của Tech", "Hạnh's iPhone") are listed but
  offline and were not used.
- Extra remote branch found, **not** in either doc's merge list, **not merged**:
  `final/latency-tuning`. Flagging for the user rather than guessing whether it belongs.

## Required build flags (discovered via baseline build on bare `main`)

Xcode 26's SPM trust gates block a from-scratch CLI build twice before it ever reaches app code:

1. `Validate plug-in "CudaBuild" in package "mlx-swift"` → needs `-skipPackagePluginValidation`.
2. `Macro "MLXHuggingFaceMacros" from package "mlx-swift-lm" was changed since a previous
   approval` → needs `-skipMacroValidation`.

Every `xcodebuild` invocation for the rest of this run uses both flags. Neither is a protocol
change or a code change — it's a one-time CLI trust bypass equivalent to clicking "Trust & Enable"
in Xcode's GUI on first open.

## Local file dependency (not a merge issue)

`App/Backend/Configs/Secrets.swift` (gitignored, holds Kaggle credentials for
`MedicalAnchorLoader`) exists untracked in the main checkout but is not shared by git worktrees
(only tracked files are). Copied it from the main checkout into this worktree once; it is not a
branch artifact and needs no further action per-branch.

## Baseline gate results (bare `main`, before any `final/*` merge)

| Gate | Result |
|---|---|
| G1 build (simulator, iPhone 17 Pro) | ✅ BUILD SUCCEEDED (with the two flags above) |
| G3 Python tests | N/A — `Pipeline/eval/tests/` does not exist yet on `main`; `final/eval-integrity` adds it. Confirmed `Pipeline/eval/` exists but has no `tests/` subpackage. |
| G4 Privacy | N/A — `Tools/privacy_audit.sh` does not exist yet on `main`; `final/privacy-audit` adds it. |
| `.gitignore` / `Package.resolved` | Confirmed currently ignored via the blanket `*.xcodeproj` rule, matching Test-Protocol.md §0's statement that this is fixed only once `final/mlx-runtime-knobs` merges. |

No code changes were made to fix any of the above — all three are expected, documented gaps that
the first branches in the sequence exist to fill.
