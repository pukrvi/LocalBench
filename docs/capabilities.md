# LocalBench capability report

**Measured, not assumed.** Every number below was produced by running LocalBench
on the development machine (`localbench capabilities`, the M0 spike, and a real
Apple-only benchmark run on 2026-11-13). Values are machine- and
OS-version-specific; re-run `localbench capabilities` on your own machine to get
yours. Nothing here is taken from documentation or guessed.

## Environment (measured 2026-11-13)

| Property | Value |
|---|---|
| OS | macOS 27.0.1 (build 26A434) |
| Chip | Apple M5 Pro, 18 cores |
| RAM | 64 GB |
| Thermal | nominal, low-power off |
| Toolchain | Xcode 27.2 (27B52), Swift 6.4.2 |

## Apple FoundationModels (measured)

| Property | Value | Source |
|---|---|---|
| Availability | available | `localbench capabilities` |
| Model ID | `AFM 3 Core Advanced` | runtime identity report |
| Context size | **8192 tokens** | runtime identity report |
| Vision (images) | supported | runtime capabilities |
| Guided generation | supported | runtime capabilities |
| Tool calling | supported | runtime capabilities |
| Reasoning | **not supported** | runtime capabilities |
| Network | on-device only; `SystemLanguageModel.default` with `.onDevice` guard | code path, never uses Private Cloud Compute |

### Measured latency / tokens (M0 spike)

| Metric | Value |
|---|---|
| TTFT (spike) | ~688 ms |
| Usage | in 73 / out 31 tokens, provenance **native** |
| Process footprint during inference | 3.7 → 9.3 MB (process self; **not** model RAM — the model is hosted by the system, outside this process) |

### Measured benchmark (CLI run, 3 reps + prewarm, stateless, max 200 tokens)

Prompt: "Explain in three sentences why on-device inference latency differs
from server inference latency."

| Metric | Median | p95 | Notes |
|---|---|---|---|
| TTFT | 355 ms | 382 ms | rep0 labeled `cold`, reps 1–2 `warm` (prewarm pass) |
| Wall | 1627 ms | 1708 ms | end-to-end incl. teardown |
| Decode tok/s | 57.6 | 59.1 | 73 / 69 / 79 output tokens |
| Tokens | in 79, out 69–79 | | provenance **native** (`LanguageModel.Session` usage) |

Every request persisted 40–131 trace records (normalized event stream + meta
note) and `localbench verify --db` recomputed TTFT/wall/tokens/tok-s from that
raw evidence: **4/4 PASS**.

## LM Studio (measured state: not validated yet)

- `localbench capabilities` correctly reports `LM Studio not reachable at
  http://127.0.0.1:1234` when the server is not running, with actionable advice.
- End-to-end validation (discovery, streaming, native usage tokens, SSE trace
  verification against real wire data) is pending: start LM Studio's local
  server, load a model, then run
  `localbench run --backends apple,lmstudio --reps 3` followed by
  `localbench verify --db …`.
- Network policy is enforced in code: LM Studio traffic is refused for any
  non-loopback host (unit-tested; only 127.0.0.0/8, ::1, 0.0.0.0 loopback
  variants allowed).

## Honest-limitations notes (encoded in every export)

- `ttft_ms` includes queue/prefill; it is not "pure model prefill".
- Prefill tokens/s is **omitted**: neither backend exposes trustworthy prefill
  timing. `n/a` is shown instead of a fabricated number.
- Process footprint ≠ model RAM for the system-hosted Apple backend; memory
  samples are labeled by scope.
- Apple FM has no user-facing seed; a requested seed forces `.greedy` on Apple
  and applies to LM Studio only.
- Decode tok/s is approximate unless token provenance is native/server
  (recorded per row).
