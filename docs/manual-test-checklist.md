# LocalBench manual test checklist

Human-executable checks for the things automated tests cannot prove
(spec §12). Run top to bottom on a clean machine. Check the box only after the
step is observed with your own eyes.

## 0. Setup

- [ ] `xcode-select -p` points at Command Line Tools, or Xcode is selected —
      either way `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`
      makes `swift build` succeed.
- [ ] `swift test` passes (53 tests).
- [ ] LM Studio installed, local server started, one chat model loaded
      (`localbench capabilities` lists it).

## 1. Airplane mode / true offline (the core local-only proof)

- [ ] Turn on Wi-Fi airplane mode (or disconnect all networks). Loopback stays
      available on macOS.
- [ ] `localbench capabilities`: Apple reports **available**; LM Studio still
      reachable at 127.0.0.1 (server is local).
- [ ] GUI → Compare Chat: send a message with both panes enabled. Both stream
      to completion **with no network interfaces active**.
- [ ] With the app running, verify no external sockets:
      `lsof -nP -i TCP | grep -Ev "127.0.0.1|::1|\*:1234|LISTEN" | grep -i localbench`
      shows nothing.
- [ ] Turn airplane mode off again.

## 2. Network policy refusal

- [ ] GUI → Settings: set LM Studio endpoint to `http://192.168.1.50:1234`
      (a LAN address). Sending a message must fail with a
      "Non-loopback" refusal error — not a connection attempt.
- [ ] Same for `https://api.example.com/v1` and a hostname like
      `http://my-lm-studio-host:1234`.
- [ ] Restore `http://127.0.0.1:1234`.

## 3. Fair comparison (identical canonical input)

- [ ] Attach a PDF and send a question about it. Both panes answer about the
      same passages (visible in the turn detail: same `prompt_hash` for both
      backends).
- [ ] In a multi-turn conversation, the Apple pane's answer never appears in
      LM Studio's next request (turn detail → trace evidence → request body
      contains only LM Studio's own assistant turns).
- [ ] Toggle **Stateless** mode: request bodies contain no assistant messages.

## 4. Metrics honesty

- [ ] Apple pane shows tokens with provenance `native`; LM Studio pane shows
      `server`. No pane ever shows a guessed token count.
- [ ] Stop LM Studio's server, send a message: the LM Studio pane records an
      `unavailable`/`network` error; the Apple pane still completes. The
      dashboard excludes the failed side from averages and shows it as failed.
- [ ] Cancel a long streaming turn (Stop button): both panes record
      `cancelled` — recorded, not silently dropped, and excluded from
      averages.
- [ ] Memory readout in a turn detail says "process footprint; NOT model RAM
      for the system-hosted Apple backend" (or equivalent scoping note).

## 5. Trace evidence + independent verification

- [ ] Run a chat turn with both backends. Turn detail → "Verify this run" →
      green **Verified** panel (recomputed values shown).
- [ ] Turn detail → "Open in Traces" switches to the Traces section with that
      request selected.
- [ ] Traces section: LM Studio requests show a `request_body` record whose
      JSON `model` matches the model you selected, plus verbatim
      `data: {...}` SSE lines and `data: [DONE]`. Apple requests show a `meta`
      note stating no user-facing wire protocol, plus normalized `event`
      records.
- [ ] Every record shows seq, +offset ms, byte count, sha256 prefix; clicking
      a row expands the raw data; the copy button puts exact bytes on the
      pasteboard.
- [ ] "Verify all" over the whole list ends with zero FAIL rows.
- [ ] Hand-tamper check (optional but fun): copy the DB, edit one `data` value
      in `wire_traces` with `sqlite3`, run
      `localbench verify --db <copy>` — that request must FAIL with a
      sha256 mismatch, and the CLI must exit 1.

## 6. Benchmarks dashboard

- [ ] Run 3 reps sequential with prewarm: per-rep table shows rep 0 `cold`
      (prewarm excluded from aggregates, present in the record), reps labeled
      `warm`; aggregates show median/p95/mean over successes only.
- [ ] Parallel schedule runs both backends concurrently and is labeled
      contended.
- [ ] Export CSV/JSON: JSON embeds `environment`, per-result traces +
      `traces_fingerprint`, prompt hash, options, provenance notes; CSV has
      `token_provenance`, `prompt_hash`, memory columns; missing values are
      literally `n/a`.
- [ ] CSV opens in Numbers/Excel with correct quoting for prompts containing
      commas and quotes.
- [ ] After a benchmark, the run's rows link to Traces ("open") and land on
      the right request.

## 7. Persistence integrity

- [ ] Send several chat turns, kill the app mid-turn (Force Quit): reopening
      shows prior turns; the killed turn's partial evidence is still in
      `wire_traces` (nothing vanishes).
- [ ] Two sections at once (open a chat turn detail while a benchmark runs):
      no DB errors (WAL + serialized writes).
- [ ] `PRAGMA user_version` on the app DB is 2:
      `sqlite3 ~/Library/Application\ Support/LocalBench/localbench.sqlite 'PRAGMA user_version;'`
- [ ] An old v1 database (delete the `wire_traces` table on a copy) opens
      without error and gains the table back via migration.

## 8. CLI ↔ GUI consistency

- [ ] A benchmark run via CLI with `--db` pointed at the app's DB shows up in
      the GUI dashboard after refresh.
- [ ] `localbench verify --db` on the app DB passes for GUI-created requests.
