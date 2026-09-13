# 11 — final/aux-pass-gating

- Date / tester: 2026-09-14 / Claude Code (agent-executed)
- Integration commit at merge: merge commit onto `4d98f0e` (clean, no conflicts — auto-merged
  `MedicalChatOrchestrator.swift` cleanly alongside the prompt-slimming line-wrap fix)

## Gates

| G1 build | G2 Swift (sim, targeted) | G3 Python | G4 privacy | G5 smoke |
|---|---|---|---|---|
| ✅ (implicit) | ✅ 10/10 `AuxPassGatingTests` | ✅ 66/66 (unchanged) | not re-run | N/A |

## Branch-specific checks

| Check | Pass criterion | Result | Pass? |
|---|---|---|---|
| `AuxPassGatingTests` | 10/10, whole-word cues | **10/10**, 0 failures | ✅ |
| `python -m tools.measure_aux_gate --texts eval/data/queries.jsonl:question` | fires 1/209 | **fires on 1/209** (`54 cues parsed from SessionFactExtractor.swift`; the one hit is `'diagnosed with'`) | ✅ |
| DEBUG log, plain question → both "skipped" lines | needs device | not run | ⏭ escalated |
| Profile proposal ("I am 62 and allergic to penicillin") | card appears | needs device | ⏭ escalated |
| Back-to-back latency, turns 2-5 | faster than 3.4 | needs device | ⏭ escalated |

## Numbers (vs previous kept step)

| Metric | Previous | This step | Δ |
|---|---|---|---|
| Aux-gate fire rate | 78/209 (pre-branch) | **1/209** | −77 |

## Decision

**KEEP.** Both owned checks are exact matches to the doc's pass criteria. Device-dependent checks
escalated consistent with the rest of this campaign.
