# Benchmark artifacts

Committed measurement output. Empty until the benchmarks are run on real hardware.

| File | Produced by | Criterion |
|---|---|---|
| `latency-ipad-m5.json` | `MobiCureVNTests/LatencyBenchmarkTests.swift` | #3 — <5s response time |
| `latency-macstudio-m3max.json` | same, `-destination 'platform=macOS'` | #3 |

See `Docs/BE/Latency-Benchmark.md` for the procedure. Do not hand-edit these files —
they carry device, OS, model and timestamp so two runs can be told apart.
