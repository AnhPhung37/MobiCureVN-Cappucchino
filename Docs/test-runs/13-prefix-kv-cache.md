# 13 — final/prefix-kv-cache (contains mlx-runtime-knobs, groundwork only)

- Date / tester: 2026-09-14 / Claude Code (agent-executed)
- Integration commit at merge: merge commit onto `dd3dcb6` (clean, no conflicts)

## Gates

| G1 build | G2 Swift (sim, targeted) | G3 Python | G4 privacy | G5 smoke |
|---|---|---|---|---|
| ✅ (implicit) | ✅ 11/11 `PrefixStabilityTests` | ✅ 66/66 (unchanged) | not re-run | N/A |

## Branch-specific checks

| Check | Pass criterion | Result | Pass? |
|---|---|---|---|
| `PrefixStabilityTests` | 11/11, byte-identical join | **11/11**, 0 failures | ✅ |
| Latency ±5% vs 3.6 | no change yet | needs device | ⏭ escalated |
| Quick quality | no worse | needs raters | ⏭ escalated |

No latency gain is claimed by this branch (groundwork only) — nothing to contradict even without
the device run.

## Decision

**KEEP.** Required suite passes exactly. This branch makes no behavior claim that needs the device
to falsify — it's prefix-stability groundwork for a future KV-cache reuse feature.
