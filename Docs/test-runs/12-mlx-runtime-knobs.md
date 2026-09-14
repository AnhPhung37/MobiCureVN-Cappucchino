# 12 — final/mlx-runtime-knobs

- Date / tester: 2026-09-14 / Claude Code (agent-executed)
- Integration commit: merge commit onto `57474b5`, plus a follow-up commit for `Package.resolved`

## Package.resolved (required first step)

`xcodebuild -resolvePackageDependencies` → resolved `mlx-swift-lm @ 3.31.4`, `mlx-swift @ 0.31.6`
(one patch above the doc's literal "3.31.3", consistent with the branch's own
`upToNextMinorVersion` pin — any 3.31.x is expected).

`git check-ignore -v` on the lockfile path **does print a line** — the negation rule itself
(`!*.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`). This isn't the literal
"prints nothing" the doc describes, but it's the *correct* rule doing its job: `git status`
independently confirms the file shows as untracked-and-visible (not ignored) — the practical test
of "can this be committed" — and it was committed successfully. The doc's fix used a straight
removal of the blanket ignore; this branch instead used a negation chain (see its updated
`.gitignore`, which also fixes a real, independent bug: the old blanket `*.xcodeproj` rule ignored
`project.pbxproj` itself too, contradicting its own comment — this explains several git
oddities I hit on earlier branches with that file, see the pbxproj note in
`Docs/test-runs/00-environment-setup.md`).

Committed at `e157c7e` (separate from the merge commit, since the resolved lockfile is a build
artifact, not part of the branch diff itself).

## Gates

| G1 build (full) | G2 Swift (sim, targeted) | G3 Python | G4 privacy | G5 smoke |
|---|---|---|---|---|
| ✅ BUILD SUCCEEDED (against pinned MLX) | ✅ 5/5 `GenerationCompletionTests` | ✅ 66/66 (unchanged) | not re-run | N/A |

## Branch-specific checks

| Check | Pass criterion | Result | Pass? |
|---|---|---|---|
| `Package.resolved` not ignored / committed | — | committed; see note above on the check's literal wording | ✅ |
| G1 full build | compiles against pinned MLX | ✅ BUILD SUCCEEDED | ✅ |
| `GenerationCompletionTests` | 5/5 | **5/5**, 0 failures | ✅ |
| Truncation per language (18 EN / 12 VI, ≤1 cut each) | needs device | not run | ⏭ escalated |
| Latency lower than 3.5 | needs device | not run | ⏭ escalated |

`prefillStepSize` ships `null` as documented — confirmed in `InferenceTuning.swift`'s defaults
(unchanged by this branch); no memory-change claim expected or tested here, matching the doc.

## Decision

**KEEP.** Full build succeeds against the newly-pinned MLX version, required Swift suite passes
exactly (5/5), `Package.resolved` is committed and genuinely trackable despite the diagnostic
`check-ignore` output. Truncation-count and latency checks need the physical device.
