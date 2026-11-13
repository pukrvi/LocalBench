# LocalBench

Side-by-side benchmarking of **Apple Foundation Models** vs **LM Studio** —
100% on-device, with full trace evidence you can independently verify.

LocalBench chats to both backends with identical canonical input, records
per-turn metrics (TTFT, wall time, decode tok/s, tokens with provenance,
memory), persists **every request's raw evidence** to SQLite, and exports
CSV/JSON. Its core promise: **no metric has to be taken on trust** — a separate
verifier recomputes every number from the stored raw data.

- **Local only.** Apple backend is on-device Foundation Models (never Private
  Cloud Compute). LM Studio traffic is hard-refused for any non-loopback host.
- **Honest numbers.** Token counts carry provenance (native / server /
  estimated / unavailable); missing data shows `n/a`, never a fabricated value.
- **Verifiable.** LM Studio stores the exact request-body JSON plus every
  verbatim SSE line (each stamped with offset, byte count, SHA-256). Apple has
  no user-facing wire protocol, so its evidence is the normalized event stream
  plus an explicit meta note saying so.
- **Full record.** Cancellations, errors, timeouts, prewarm and
  unavailable-backend attempts are all recorded — excluded from success
  averages, never deleted.

## macOS version requirement

Requires **macOS 26+** (Foundation Models framework). Builds with **Xcode 27+**
toolchain.

If your `xcode-select` points at Command Line Tools (no Foundation Models
module), prefix every SwiftPM command with `DEVELOPER_DIR`:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

## Build & test

```bash
git clone https://github.com/pukrvi/LocalBench.git
cd LocalBench
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test   # 53 tests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -c release
```

## The GUI app

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run LocalBenchApp
```

Or build a self-contained `.app` bundle: `scripts/make-app.sh` →
`dist/LocalBench.app` (ad-hoc signed, double-clickable).

Three sections:

1. **Compare Chat** — side-by-side streaming panes (Apple | LM Studio). Each
   turn sends identical canonical user text + extracted passages to both
   backends; assistant history stays per-backend (Apple's answers are never
   replayed to LM Studio and vice versa). A metric strip under each pane shows
   TTFT / wall / tok-s / tokens (with provenance) / memory; a per-turn detail
   view shows the full result, its trace evidence, an inline **verification**
   badge, and a deep link into the Traces section.
2. **Benchmarks** — dashboard: run form (reps, sequential/parallel, stateless,
   prewarm, temperature, max tokens, seed, backend + model pickers), run
   history, per-backend aggregates (median / p95 / mean over successes only),
   per-repetition table, and CSV/JSON export with Reveal in Finder.
3. **Traces** — dedicated evidence browser: every persisted request, its raw
   records (kind, sequence, offset, byte count, SHA-256, full data,
   copyable), and a PASS/FAIL badge from independent recomputation. Reachable
   from chat turn details and benchmark rows via "Open in Traces".

The app database lives at
`~/Library/Application Support/LocalBench/localbench.sqlite` (WAL, shared by
all three sections).

## The CLI

```bash
# Capability matrix for both backends (measured, not assumed)
swift run localbench capabilities

# Apple-only, 3 repetitions, stateless, with prewarm; persists live + exports
swift run localbench run \
  --prompt "Explain why on-device latency differs from server latency." \
  --backends apple --reps 3 --stateless --max-tokens 200 \
  --db benchout/demo.sqlite --export-dir benchout

# Independent audit: recompute TTFT/wall/tokens from raw evidence
swift run localbench verify --db benchout/demo.sqlite   # exits 0 = all PASS
```

`run` also accepts `--backends apple,lmstudio`, `--schedule parallel`
(labeled *contended* — UX-only per spec), `--system "…"`, `--temperature`,
`--seed` (LM Studio only; Apple has no user-facing seed and a seed forces
greedy decoding there), `--attach file.pdf` (repeatable; text extraction with
page/offset provenance, optional `--ocr`, images only for vision models),
`--lm-url`, `--lm-model`.

`verify` checks, per request: sequence integrity, per-record SHA-256 and byte
counts, offset monotonicity, request-body model match, then **recomputes**
TTFT (first content line/event), wall (last line/event), tokens (usage), and
decode tok/s, diffing against the recorded result (timing ±150 ms, tok/s ±10%,
tokens exact). Any request can be re-derived by a human expert or another
model from `wire_traces` alone.

Example of a real run on an M5 Pro (2026-11-13, see
[docs/capabilities.md](docs/capabilities.md)):

```
[apple] rep0 warmth=cold  ttft=355ms wall=1622ms tps=57.6 tokens=in=79 out=73 (native)
[apple] rep1 warmth=warm  ttft=353ms wall=1627ms tps=54.2 tokens=in=79 out=69 (native)
[apple] rep2 warmth=warm  ttft=385ms wall=1717ms tps=59.3 tokens=in=79 out=79 (native)
```

```
[PASS] C01A2B62… apple — 40 records verify against recorded metrics
[PASS] 5EA9BD3A… apple — 119 records verify against recorded metrics
[PASS] E829DEC1… apple — 121 records verify against recorded metrics
[PASS] 308EA738… apple — 131 records verify against recorded metrics
verified 4 request(s), 0 failing
```

## LM Studio setup

1. Install [LM Studio](https://lmstudio.ai), open the **Developer** tab, start
   the local server (default `http://127.0.0.1:1234`).
2. Load a chat model.
3. `localbench capabilities` should list the model; then run benchmarks with
   `--backends apple,lmstudio`.

## What gets persisted (SQLite, schema v2)

`conversations`, `turns`, `attachments` (+ `extracted_passages` + FTS5 index),
`model_configs` (identity snapshots), `requests` (full envelope JSON),
`results` (all metrics + provenance + error kind), `wire_traces` (**the raw
evidence** — request body / verbatim SSE lines / normalized events / meta
notes, each with seq, offset ms, byte count, SHA-256), `metric_samples`
(footprint + pressure timeline), `benchmark_runs` (+ aggregates JSON),
`stream_events`, `evaluations` (thumbs/rubric).

## Project layout

```
Sources/LocalBenchCore/       # backends, metrics, benchmark runner, SQLite,
                              # trace capture + verifier, exports, attachments
Sources/LocalBenchApp/        # SwiftUI app: Compare Chat / Benchmarks / Traces
Sources/localbench/           # CLI: capabilities / run / verify
Sources/Spike/                # M0 capability probe (one-shot)
Tests/LocalBenchCoreTests/    # 53 tests: SSE/hostile-chunking, network policy,
                              # history isolation, store, trace verification,
                              # aggregates, exports, provenance semantics
docs/capabilities.md          # measured capability + latency report
docs/manual-test-checklist.md # airplane-mode & integrity manual tests
scripts/make-app.sh           # build dist/LocalBench.app
```

## Design rules this project holds itself to

- On-device or loopback only; the network policy is unit-tested (remote hosts,
  non-HTTP schemes, malformed URLs all rejected).
- Token provenance is recorded per result: `native` (Apple `LanguageModel`
  usage), `server` (LM Studio `usage`), or explicitly unavailable — no
  estimating dressed up as measurement.
- Failures, cancellations, prewarm, and unavailable backends are first-class
  records; success aggregates exclude them and say so in the UI.
- Exports embed prompt/attachment hashes, model identity, run mode, sampling
  options, OS/hardware, units, provenance notes, and the full trace set with a
  chained SHA-256 fingerprint.

No telemetry, no network calls beyond loopback, no third-party dependencies
(system SQLite via `import SQLite3` only).
