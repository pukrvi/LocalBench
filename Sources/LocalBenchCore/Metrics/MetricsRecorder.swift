import Foundation

/// Metric math with explicit definitions (spec §6). All pure + unit-tested.
public enum Metrics {
    /// TTFT in ms: first nonempty content time − dispatch time.
    public static func ttftMS(dispatchNS: UInt64, firstContentNS: UInt64) -> Double {
        Double(firstContentNS > dispatchNS ? firstContentNS - dispatchNS : 0) / 1_000_000
    }

    /// End-to-end latency in ms: last completion − dispatch.
    public static func wallMS(dispatchNS: UInt64, endNS: UInt64) -> Double {
        Double(endNS > dispatchNS ? endNS - dispatchNS : 0) / 1_000_000
    }

    /// Decode tokens/sec = output tokens ÷ (end − first content). Approximate
    /// unless the token count is exact (provenance recorded separately).
    ///
    /// Short responses can arrive in a single immediate snapshot; a
    /// sub-50 ms window is burst delivery, not a steady-state decode rate, so
    /// reporting tokens/very-small-number would invent physically impossible
    /// throughput. Such runs return nil ("unavailable") instead.
    public static let minimumDecodeWindowNS: UInt64 = 50_000_000

    public static func outputTokensPerSecond(outputTokens: Int?, firstContentNS: UInt64?, endNS: UInt64) -> Double? {
        guard let outputTokens, outputTokens > 0, let firstContentNS else { return nil }
        guard endNS > firstContentNS else { return nil }
        let windowNS = endNS - firstContentNS
        guard windowNS >= minimumDecodeWindowNS else { return nil }
        let seconds = Double(windowNS) / 1_000_000_000
        return Double(outputTokens) / seconds
    }

    /// Nearest-rank median of a numeric list (nil for empty input).
    public static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let count = sorted.count
        if count % 2 == 1 {
            return sorted[count / 2]
        }
        return (sorted[count / 2 - 1] + sorted[count / 2]) / 2
    }

    /// Linear-interpolation percentile (e.g. p95). nil for empty input.
    public static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        guard sorted.count > 1 else { return sorted[0] }
        let rank = p / 100 * Double(sorted.count - 1)
        let lower = Int(rank.rounded(.down))
        let upper = Int(rank.rounded(.up))
        guard lower != upper else { return sorted[lower] }
        let fraction = rank - Double(lower)
        return sorted[lower] * (1 - fraction) + sorted[upper] * fraction
    }

    /// Success values only: cancelled/failed runs are excluded from averages
    /// but never deleted from the record (spec §12).
    public static func successes(_ envelopes: [ResultEnvelope], _ pick: (ResultEnvelope) -> Double?) -> [Double] {
        envelopes.filter { !$0.isError }.compactMap(pick)
    }

    /// Monotonic wall-clock nanoseconds (mach uptime) for cross-backend comparisons.
    public static func nowMonotonicNS() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }
}

/// Converts a normalized StreamEvent sequence into a ResultEnvelope.
public struct MetricsRecorder: Sendable {
    public init() {}

    public struct Output: Sendable {
        public var result: ResultEnvelope
        public init(result: ResultEnvelope) { self.result = result }
    }

    /// Consume one backend's stream, building the ResultEnvelope. Cancellation
    /// and errors are recorded and marked isError (excluded from averages).
    /// `onEvent` observes every event exactly once (used for live UI updates).
    /// `capture` receives a JSON-encoded copy of every event plus a re-anchored
    /// clock (offsets in the capture are relative to dispatch time), so traces
    /// can be independently recomputed later.
    public func record(envelope: RequestEnvelope,
                       backend: BackendID,
                       modelID: String,
                       identity: BackendIdentity?,
                       events: AsyncThrowingStream<StreamEvent, Error>,
                       repetitionIndex: Int,
                       memorySampler: MemorySampler?,
                       onEvent: (@Sendable (StreamEvent) -> Void)? = nil,
                       capture: StreamCapture? = nil) async -> ResultEnvelope {
        let dispatchNS = Metrics.nowMonotonicNS()
        capture?.resetClock()
        var firstContentNS: UInt64?
        var text = ""
        var inputTokens: Int?
        var outputTokens: Int?
        var cachedTokens: Int?
        var reasoningTokens: Int?
        var provenance = TokenProvenance.unavailable
        var toolCalls: [ToolCall] = []
        var finishReason: FinishReason = .unknown
        var error: BackendError?
        var ended = false
        let environment = AppEnvironment.current()

        await memorySampler?.start()

        do {
            for try await event in events {
                onEvent?(event)
                capture?.append(kind: .event, data: JSONCoding.encode(event))
                switch event {
                case .started:
                    break
                case .delta(_, let delta):
                    if firstContentNS == nil {
                        firstContentNS = Metrics.nowMonotonicNS()
                    }
                    text += delta
                case .usage(_, let inTokens, let outTokens, let cached, let reasoning, let source):
                    if source == .native || source == .server {
                        if let inTokens { inputTokens = inTokens }
                        if let outTokens { outputTokens = outTokens }
                        if let cached { cachedTokens = cached }
                        if let reasoning { reasoningTokens = reasoning }
                        provenance = source
                    } else if provenance == .unavailable {
                        provenance = source
                    }
                case .finished(_, let reason, _):
                    finishReason = reason
                    ended = true
                case .toolCall(_, let call):
                    toolCalls.append(call)
                case .failed(_, let failure, _):
                    error = failure
                    finishReason = failure.finishReason
                    ended = true
                }
            }
        } catch is CancellationError {
            error = .cancelled()
            finishReason = .cancelled
            ended = true
        } catch let thrown {
            let backendError = (thrown as? BackendError) ?? BackendError(kind: .unknown, message: String(describing: thrown))
            error = backendError
            finishReason = backendError.finishReason
            ended = true
        }

        let endNS = Metrics.nowMonotonicNS()
        let ttft = firstContentNS.map { Metrics.ttftMS(dispatchNS: dispatchNS, firstContentNS: $0) }
        let wall = Metrics.wallMS(dispatchNS: dispatchNS, endNS: endNS)
        let speed = Metrics.outputTokensPerSecond(outputTokens: outputTokens, firstContentNS: firstContentNS, endNS: endNS)

        await memorySampler?.stop()
        let memory = await memorySampler?.summary()
        let traces = capture?.snapshot() ?? []
        let fingerprint = capture?.fingerprint() ?? ""

        return ResultEnvelope(
            requestID: envelope.requestID,
            conversationID: envelope.conversationID,
            turnIndex: envelope.turnIndex,
            backend: backend,
            modelID: modelID,
            osVersion: environment.osVersion,
            osBuild: environment.osBuild,
            dispatchMonotonicNS: dispatchNS,
            firstContentMonotonicNS: firstContentNS,
            endMonotonicNS: endNS,
            ttftMS: ttft,
            wallMS: wall,
            outputTokensPerSecond: speed,
            prefillTokensPerSecond: nil, // no trustworthy prefill timing from either backend (spec §6)
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cachedTokens: cachedTokens,
            reasoningTokens: reasoningTokens,
            tokenProvenance: provenance,
            peakProcessFootprintMB: memory?.peakFootprintMB,
            systemPeakPressureLevel: memory?.peakPressureLevel,
            memoryScopeNote: memory?.scopeNote ?? "unsampled",
            memorySamples: memory?.samples ?? [],
            rawText: text,
            toolCalls: toolCalls,
            finishReason: ended ? finishReason : .unknown,
            error: error,
            warmth: .unknown, // set by BenchmarkRunner
            repetitionIndex: repetitionIndex,
            schedule: envelope.schedule,
            mode: envelope.mode,
            options: envelope.options,
            promptHash: envelope.promptHash,
            attachmentSHA256s: envelope.attachmentSHA256s,
            traces: traces,
            tracesFingerprint: fingerprint,
            backendSettingsJSON: identity.map { JSONCoding.encode($0) } ?? "{}"
        )
    }
}

enum JSONCoding {
    static func encode<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
