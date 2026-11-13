import Testing
import Foundation
@testable import LocalBenchCore

@Suite("Metrics definitions")
struct MetricsTests {
    @Test func ttftAndWallMath() {
        let dispatch: UInt64 = 1_000_000_000 // 1s
        let first: UInt64 = 1_600_000_000    // +600ms
        let end: UInt64 = 3_200_000_000      // +2200ms
        #expect(abs(Metrics.ttftMS(dispatchNS: dispatch, firstContentNS: first) - 600) < 0.0001)
        #expect(abs(Metrics.wallMS(dispatchNS: dispatch, endNS: end) - 2200) < 0.0001)
    }

    @Test func decodeSpeedUsesFirstContentToEnd() {
        let first: UInt64 = 1_000_000_000
        let end: UInt64 = 4_000_000_000 // 3s window
        let speed = Metrics.outputTokensPerSecond(outputTokens: 90, firstContentNS: first, endNS: end)
        #expect(abs(speed! - 30) < 0.0001)
        #expect(Metrics.outputTokensPerSecond(outputTokens: nil, firstContentNS: first, endNS: end) == nil)
        #expect(Metrics.outputTokensPerSecond(outputTokens: 10, firstContentNS: nil, endNS: end) == nil)
    }

    @Test func medianNearestRank() {
        #expect(Metrics.median([]) == nil)
        #expect(Metrics.median([3.0]) == 3.0)
        #expect(Metrics.median([5, 1, 3]) == 3.0)
        #expect(Metrics.median([4, 2]) == 3.0)
    }

    @Test func percentileLinearInterpolation() {
        #expect(Metrics.percentile([1.0], 95) == 1.0)
        let values = (1...100).map { Double($0) }
        #expect(abs(Metrics.percentile(values, 95)! - 95.05) < 0.001)
        #expect(abs(Metrics.percentile(values, 50)! - 50.5) < 0.001)
    }

    @Test func successesExcludeErrorsAndCancellations() {
        let ok = ResultEnvelope(
            requestID: "r1", conversationID: "c", turnIndex: 0, backend: .apple, modelID: "m",
            osVersion: "27.0.1", osBuild: "26A434",
            dispatchMonotonicNS: 0, firstContentMonotonicNS: 100, endMonotonicNS: 900,
            ttftMS: 100, wallMS: 900, outputTokensPerSecond: 10,
            outputTokens: 8, tokenProvenance: .native, rawText: "ok", finishReason: .stop
        )
        var failed = ok
        failed.error = BackendError(kind: .serverError, message: "boom")
        var cancelled = ok
        cancelled.error = .cancelled()
        let picked = Metrics.successes([ok, failed, cancelled]) { $0.ttftMS }
        #expect(picked == [100])
    }
}

@Suite("Token provenance")
struct TokenProvenanceTests {
    @Test func nativeUsageRecorded() async {
        let recorder = MetricsRecorder()
        let envelope = RequestEnvelope(conversationID: "c", turnIndex: 0, canonicalUserText: "hi")
        let events = makeStream([
            .started(backend: .apple, at: Date()),
            .delta(backend: .apple, text: "one two"),
            .usage(backend: .apple, inputTokens: 73, outputTokens: 31, cachedTokens: 0, reasoningTokens: 0, provenance: .native),
            .finished(backend: .apple, reason: .stop, at: Date()),
        ])
        let result = await recorder.record(envelope: envelope, backend: .apple, modelID: "m", identity: nil, events: events, repetitionIndex: 0, memorySampler: nil)
        #expect(result.tokenProvenance == .native)
        #expect(result.inputTokens == 73)
        #expect(result.outputTokens == 31)
        #expect(result.rawText == "one two")
    }

    @Test func noUsageStaysUnavailable() async {
        let recorder = MetricsRecorder()
        let envelope = RequestEnvelope(conversationID: "c", turnIndex: 0, canonicalUserText: "hi")
        let events = makeStream([
            .started(backend: .lmStudio, at: Date()),
            .delta(backend: .lmStudio, text: "hello world this is a long text"),
            .finished(backend: .lmStudio, reason: .stop, at: Date()),
        ])
        let result = await recorder.record(envelope: envelope, backend: .lmStudio, modelID: "m", identity: nil, events: events, repetitionIndex: 0, memorySampler: nil)
        #expect(result.tokenProvenance == .unavailable)
        #expect(result.inputTokens == nil)
        #expect(result.outputTokens == nil)
    }

    @Test func serverUsageWinsOverNothingAndNeverFakesExactness() async {
        let recorder = MetricsRecorder()
        let envelope = RequestEnvelope(conversationID: "c", turnIndex: 0, canonicalUserText: "hi")
        let events = makeStream([
            .started(backend: .lmStudio, at: Date()),
            .delta(backend: .lmStudio, text: "hey"),
            .usage(backend: .lmStudio, inputTokens: 11, outputTokens: 18, cachedTokens: nil, reasoningTokens: nil, provenance: .server),
            .finished(backend: .lmStudio, reason: .stop, at: Date()),
        ])
        let result = await recorder.record(envelope: envelope, backend: .lmStudio, modelID: "m", identity: nil, events: events, repetitionIndex: 0, memorySampler: nil)
        #expect(result.tokenProvenance == .server)
        #expect(result.inputTokens == 11)
        #expect(result.outputTokens == 18)
    }

    @Test func cancellationRecordedNotSilent() async {
        let recorder = MetricsRecorder()
        let envelope = RequestEnvelope(conversationID: "c", turnIndex: 0, canonicalUserText: "hi")
        let events = makeStream([
            .started(backend: .apple, at: Date()),
            .delta(backend: .apple, text: "partial"),
            .failed(backend: .apple, error: .cancelled(), at: Date()),
        ])
        let result = await recorder.record(envelope: envelope, backend: .apple, modelID: "m", identity: nil, events: events, repetitionIndex: 0, memorySampler: nil)
        #expect(result.isCancelled)
        #expect(result.finishReason == .cancelled)
        #expect(result.rawText == "partial") // partial output preserved
    }

    @Test func malformedStreamYieldsError() async {
        struct Boom: Error {}
        let recorder = MetricsRecorder()
        let envelope = RequestEnvelope(conversationID: "c", turnIndex: 0, canonicalUserText: "hi")
        let stream = AsyncThrowingStream<StreamEvent, Error> { continuation in
            continuation.yield(.started(backend: .lmStudio, at: Date()))
            continuation.finish(throwing: Boom())
        }
        let result = await recorder.record(envelope: envelope, backend: .lmStudio, modelID: "m", identity: nil, events: stream, repetitionIndex: 0, memorySampler: nil)
        #expect(result.isError)
        #expect(result.error?.kind == .unknown)
    }

    func makeStream(_ sequence: [StreamEvent]) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            for event in sequence {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }
}
