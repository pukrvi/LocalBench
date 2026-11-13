import Foundation
import Testing
@testable import LocalBenchCore

@Suite("Trace capture & verification")
struct VerificationAndTraceTests {

    // MARK: Capture mechanics

    @Test func captureStampsSeqOffsetHashAndByteCount() {
        let capture = StreamCapture()
        capture.append(kind: .requestBody, data: #"{"model":"m"}"#)
        capture.append(kind: .sseLine, data: "data: [DONE]")
        let records = capture.snapshot()
        #expect(records.count == 2)
        #expect(records[0].seq == 0)
        #expect(records[1].seq == 1)
        #expect(records[0].sha256 == Sha256.hex(#"{"model":"m"}"#))
        #expect(records[1].byteCount == "data: [DONE]".utf8.count)
        #expect(records.allSatisfy { $0.offsetMS >= 0 })
        #expect(records[1].offsetMS >= records[0].offsetMS)
    }

    @Test func captureFingerprintPinsContent() {
        let a = StreamCapture()
        a.append(kind: .meta, data: "same")
        let b = StreamCapture()
        b.append(kind: .meta, data: "same")
        let c = StreamCapture()
        c.append(kind: .meta, data: "different")
        #expect(a.fingerprint() == b.fingerprint())
        #expect(a.fingerprint() != c.fingerprint())
    }

    @Test func captureIsThreadSafeUnderConcurrentAppends() async {
        let capture = StreamCapture()
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<100 {
                group.addTask {
                    capture.append(kind: .event, data: "record-\(index)")
                }
            }
        }
        let records = capture.snapshot()
        #expect(records.count == 100)
        #expect(Set(records.map { $0.seq }).count == 100) // unique, gapless sequence
        #expect(records.map { $0.seq } == Array(0..<100))
    }

    // MARK: Recorder → capture integration

    @Test func recorderEncodesEveryEventIntoCapture() async {
        let envelope = RequestEnvelope(conversationID: "c", turnIndex: 0, canonicalUserText: "q")
        let events: [StreamEvent] = [
            .started(backend: .apple, at: Date()),
            .delta(backend: .apple, text: "Hello"),
            .usage(backend: .apple, inputTokens: 7, outputTokens: 2, cachedTokens: nil, reasoningTokens: nil, provenance: .native),
            .finished(backend: .apple, reason: .stop, at: Date()),
        ]
        let stream = AsyncThrowingStream<StreamEvent, Error> { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
        let capture = StreamCapture()
        let recorder = MetricsRecorder()
        let result = await recorder.record(
            envelope: envelope, backend: .apple, modelID: "AFM 3", identity: nil,
            events: stream, repetitionIndex: 0, memorySampler: nil, capture: capture
        )

        let traces = capture.snapshot()
        #expect(traces.count == events.count)
        #expect(traces.allSatisfy { $0.kind == .event })
        #expect(result.traces == traces)
        #expect(result.tracesFingerprint == capture.fingerprint())
        #expect(!result.tracesFingerprint.isEmpty)

        // Every encoded event must decode back to the original event.
        for (record, original) in zip(traces, events) {
            let decoded = try? JSONDecoder().decode(StreamEvent.self, from: Data(record.data.utf8))
            #expect(decoded != nil)
            if let decoded {
                if case .delta(_, let text) = decoded, case .delta(_, let originalText) = original {
                    #expect(text == originalText)
                }
            }
        }
    }

    // MARK: LM Studio raw-evidence recomputation

    /// Synthetic but structurally identical to real LM Studio SSE traffic:
    /// request body, content lines, a usage line, and the [DONE] sentinel.
    func syntheticLMStudioRecords() -> [TraceRecord] {
        let body = #"{"model":"qwen3-8b","stream":true,"stream_options":{"include_usage":true},"messages":[{"role":"user","content":"Count from one to ten."}]}"#
        let line1 = #"data: {"id":"c1","choices":[{"delta":{"content":"one two three"}}]}"#
        let line2 = #"data: {"id":"c1","choices":[{"delta":{"content":" four five"}}]}"#
        let usage = #"data: {"id":"c1","choices":[],"usage":{"prompt_tokens":73,"completion_tokens":5,"total_tokens":78}}"#
        let done = "data: [DONE]"
        let entries: [(TraceRecord.Kind, String, Double)] = [
            (.requestBody, body, 0),
            (.sseLine, line1, 120),
            (.sseLine, line2, 220),
            (.sseLine, usage, 990),
            (.sseLine, done, 1000),
        ]
        return entries.enumerated().map { index, entry in
            TraceRecord(
                seq: index,
                kind: entry.0,
                offsetMS: entry.2,
                byteCount: entry.1.utf8.count,
                sha256: Sha256.hex(entry.1),
                data: entry.1
            )
        }
    }

    @Test func verifierRecomputesLMStudioMetricsFromRawEvidence() {
        let records = syntheticLMStudioRecords()
        // TTFT = first content line offset (120), wall = last line offset (1000),
        // tokens from usage line, tps = 5 / ((1000-120)/1000).
        let expected = TraceVerifier.Expected(
            modelID: "qwen3-8b",
            ttftMS: 120,
            wallMS: 1000,
            outputTokensPerSecond: 5.0 / 0.88,
            inputTokens: 73,
            outputTokens: 5,
            tokenProvenance: "server"
        )
        let report = TraceVerifier.verify(records: records, expected: expected)
        #expect(report.passed)
        #expect(report.recomputedTTFTMS == 120)
        #expect(report.recomputedWallMS == 1000)
        #expect(report.recomputedInputTokens == 73)
        #expect(report.recomputedOutputTokens == 5)
        #if DEBUG
        if !report.passed {
            for finding in report.findings { print("finding: \(finding)") }
        }
        #endif
    }

    @Test func verifierFlagsTamperedEvidence() {
        var records = syntheticLMStudioRecords()
        // Swap two records' hashes: content no longer matches its claimed hash.
        records[1].sha256 = records[2].sha256
        let report = TraceVerifier.verify(records: records, expected: nil)
        #expect(!report.passed)
        #expect(report.findings.contains { $0.contains("sha256 mismatch") })
    }

    @Test func verifierFlagsFabricatedMetrics() {
        var records = syntheticLMStudioRecords()
        // Claim TTFT/wall far beyond the standard ±150 ms capture-skew
        // tolerance, plus wrong token counts.
        let expected = TraceVerifier.Expected(
            modelID: "qwen3-8b",
            ttftMS: 300, // trace says first content at 120 ms
            wallMS: 30,  // trace says last line at 1000 ms
            outputTokensPerSecond: nil,
            inputTokens: 1,
            outputTokens: 999
        )
        records.removeLast() // drop [DONE] so wall recompute = 990; still far from 30
        let report = TraceVerifier.verify(records: records, expected: expected)
        #expect(!report.passed)
        #expect(report.findings.contains { $0.contains("ttft_ms") })
        #expect(report.findings.contains { $0.contains("wall_ms") })
        #expect(report.findings.contains { $0.contains("input tokens") })
        #expect(report.findings.contains { $0.contains("output tokens") })
    }

    @Test func verifierChecksModelIdentityAgainstRequestBody() {
        let records = syntheticLMStudioRecords()
        let expected = TraceVerifier.Expected(modelID: "different-model")
        let report = TraceVerifier.verify(records: records, expected: expected)
        #expect(!report.passed)
        #expect(report.findings.contains { $0.contains("model") })
    }

    // MARK: Apple normalized-evidence path

    @Test func verifierHandlesAppleNormalizedOnlyEvidence() {
        let eventJSON: (StreamEvent) -> String = { event in
            let data = try! JSONEncoder().encode(event)
            return String(decoding: data, as: UTF8.self)
        }
        let started = StreamEvent.started(backend: .apple, at: Date())
        let delta = StreamEvent.delta(backend: .apple, text: "one")
        let usage = StreamEvent.usage(backend: .apple, inputTokens: 7, outputTokens: 1, cachedTokens: nil, reasoningTokens: nil, provenance: .native)
        let finished = StreamEvent.finished(backend: .apple, reason: .stop, at: Date())
        let meta = "Apple FoundationModels exposes no user-facing wire protocol; trace evidence is the normalized event stream only"
        let entries: [(TraceRecord.Kind, String, Double)] = [
            (.meta, meta, 0),
            (.event, eventJSON(started), 0.5),
            (.event, eventJSON(delta), 300),
            (.event, eventJSON(usage), 310),
            (.event, eventJSON(finished), 900),
        ]
        let records = entries.enumerated().map { index, entry in
            TraceRecord(seq: index, kind: entry.0, offsetMS: entry.2, byteCount: entry.1.utf8.count, sha256: Sha256.hex(entry.1), data: entry.1)
        }
        let expected = TraceVerifier.Expected(
            modelID: "AFM 3 Core Advanced",
            ttftMS: 300,
            wallMS: 900,
            outputTokensPerSecond: nil,
            inputTokens: 7,
            outputTokens: 1,
            tokenProvenance: "native"
        )
        let report = TraceVerifier.verify(records: records, expected: expected)
        #expect(report.passed)
        #expect(report.recomputedTTFTMS == 300)
        #expect(report.recomputedWallMS == 900)
        #expect(report.recomputedInputTokens == 7)
        #expect(report.recomputedOutputTokens == 1)
    }

    // MARK: Store roundtrip + FK

    @Test func storeRoundtripsTracesAndEnforcesRequestFK() throws {
        let store = try SQLiteStore.inMemory()

        // FK: traces require an existing request row.
        let orphan = StreamCapture()
        orphan.append(kind: .meta, data: "orphan")
        #expect(throws: (any Error).self) {
            try store.saveTraces(orphan.snapshot(), requestID: "no-such-request")
        }

        let envelope = RequestEnvelope(conversationID: "c", turnIndex: 0, canonicalUserText: "q")
        let turn = Turn(turnIndex: 0, canonicalUserText: "q")
        try store.saveTurn(turn, conversationID: "c")
        try store.saveRequest(envelope: envelope, turnID: turn.id, backend: .apple)
        let records = syntheticLMStudioRecords() + [TraceRecord(
            seq: 5, kind: .meta, offsetMS: 0, byteCount: 3, sha256: Sha256.hex("abc"), data: "abc"
        )]
        try store.saveTraces(records, requestID: envelope.requestID)
        let loaded = try store.wireTraces(requestID: envelope.requestID)
        #expect(loaded == records)

        // Idempotent re-save.
        try store.saveTraces(records, requestID: envelope.requestID)
        #expect(try store.wireTraces(requestID: envelope.requestID).count == records.count)

        try store.deleteAll()
        #expect(try store.wireTraces(requestID: envelope.requestID).isEmpty)
    }

    /// Regression: `INSERT OR REPLACE` on parent rows (conversations/turns/
    /// requests) used to delete-then-insert, firing ON DELETE CASCADE and
    /// silently wiping the previous repetition's results and trace evidence.
    /// Re-saving parents (as the runner does every repetition) must be
    /// non-destructive.
    @Test func reSavingParentRowsNeverCascadesAwayEvidence() throws {
        let store = try SQLiteStore.inMemory()

        func persistRep(_ index: Int) throws -> String {
            let envelope = RequestEnvelope(conversationID: "bench", turnIndex: index, canonicalUserText: "q")
            let turn = Turn(id: "turn-\(envelope.requestID)", turnIndex: index, canonicalUserText: "q")
            try store.saveTurn(turn, conversationID: "bench")
            try store.saveRequest(envelope: envelope, turnID: turn.id, backend: .apple)
            let capture = StreamCapture()
            capture.append(kind: .meta, data: "evidence for rep \(index)")
            try store.saveTraces(capture.snapshot(), requestID: envelope.requestID)
            return envelope.requestID
        }

        let rep0 = try persistRep(0)
        let rep1 = try persistRep(1)
        let rep2 = try persistRep(2)

        // All three repetitions' evidence must still be present.
        for requestID in [rep0, rep1, rep2] {
            let traces = try store.wireTraces(requestID: requestID)
            #expect(traces.count == 1, "evidence for \(requestID) was cascaded away by a later parent upsert")
        }
        var turns = 0
        try store.query("SELECT COUNT(*) FROM turns") { row in turns = row.int(0) ?? 0 }
        #expect(turns == 3)
    }

    // MARK: Runner persists everything live

    struct MockBackend: ChatBackend {
        let id: BackendID = .apple
        let events: [StreamEvent]
        /// Real-time pacing (ms) before each event. Instant streams make tok/s
        /// recomputation sub-millisecond noise; pacing gives the verifier a
        /// macro-scale decode window to check within tolerance.
        let delaysMS: [Double]

        init(events: [StreamEvent], delaysMS: [Double] = []) {
            self.events = events
            self.delaysMS = delaysMS
        }

        func availabilityReport() async -> AvailabilityReport {
            AvailabilityReport(
                backend: .apple,
                isAvailable: true,
                reason: "available (test double)",
                actionableAdvice: "",
                identity: BackendIdentity(
                    backend: .apple,
                    modelID: "mock-afm",
                    displayName: "Mock AFM",
                    capabilities: CapabilityReport(text: true, streaming: true, images: false, guidedGeneration: true, toolCalling: false, reasoning: false),
                    osVersion: "test",
                    osBuild: "test"
                )
            )
        }

        func stream(_ envelope: RequestEnvelope) -> AsyncThrowingStream<StreamEvent, Error> {
            AsyncThrowingStream { continuation in
                let task = Task {
                    for (index, event) in events.enumerated() {
                        if index < delaysMS.count, delaysMS[index] > 0 {
                            try? await Task.sleep(nanoseconds: UInt64(delaysMS[index] * 1_000_000))
                        }
                        continuation.yield(event)
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    @Test func runnerPersistsTurnRequestResultSamplesAndTracesLive() async throws {
        let store = try SQLiteStore.inMemory()
        let backend = MockBackend(
            events: [
                .started(backend: .apple, at: Date()),
                .delta(backend: .apple, text: "Hi there"),
                .usage(backend: .apple, inputTokens: 5, outputTokens: 2, cachedTokens: nil, reasoningTokens: nil, provenance: .native),
                .finished(backend: .apple, reason: .stop, at: Date()),
            ],
            delaysMS: [0, 100, 30, 170] // decode window ≈ 200 ms → tok/s ≈ 10
        )
        var backends: [BackendID: ChatBackend] = [:]
        backends[.apple] = backend
        let runner = BenchmarkRunner(backends: backends, store: store)
        var configuration = BenchmarkRunner.Configuration(prompt: "say hi", repetitions: 1)
        configuration.prewarm = false

        let run = await runner.run(configuration: configuration)
        #expect(run.results.count == 1)

        var turns = 0
        try store.query("SELECT COUNT(*) FROM turns") { row in turns = row.int(0) ?? 0 }
        var requests = 0
        try store.query("SELECT COUNT(*) FROM requests") { row in requests = row.int(0) ?? 0 }
        var results = 0
        try store.query("SELECT COUNT(*) FROM results") { row in results = row.int(0) ?? 0 }
        var traces = 0
        try store.query("SELECT COUNT(*) FROM wire_traces") { row in traces = row.int(0) ?? 0 }
        var metricSamples = 0
        try store.query("SELECT COUNT(*) FROM metric_samples") { row in metricSamples = row.int(0) ?? 0 }
        var identities = 0
        try store.query("SELECT COUNT(*) FROM model_configs") { row in identities = row.int(0) ?? 0 }

        #expect(turns == 1)
        #expect(requests == 1)
        #expect(results == 1)
        // 4 normalized events + 1 apple meta note
        #expect(traces == 5)
        #expect(metricSamples >= 0)
        #expect(identities == 1)

        // The persisted traces must verify against the persisted result.
        var requestIDs: [String] = []
        try store.query("SELECT id FROM requests") { row in requestIDs.append(row.text(0) ?? "") }
        #expect(requestIDs.count == 1)
        let records = try store.wireTraces(requestID: requestIDs[0])
        #expect(records.count == 5)
        let savedResult = run.results[0]
        let report = TraceVerifier.verify(records: records, expected: TraceVerifier.Expected(savedResult))
        #expect(report.passed)
    }
}
