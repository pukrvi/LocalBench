import Foundation

/// One controlled benchmark run: a set of ResultEnvelopes produced under one
/// schedule with N repetitions (spec §5).
public struct BenchmarkRun: Codable, Sendable {
    public var id: String
    public var label: String
    public var conversationID: String?
    public var schedule: RunSchedule
    public var repetitions: Int
    public var stateless: Bool
    public var orderSeed: String?
    public var startedAt: Date
    public var finishedAt: Date?
    public var results: [ResultEnvelope]
    public var aggregatesJSON: String?

    public init(id: String = UUID().uuidString,
                label: String,
                conversationID: String? = nil,
                schedule: RunSchedule,
                repetitions: Int,
                stateless: Bool,
                orderSeed: String? = nil,
                startedAt: Date = Date(),
                finishedAt: Date? = nil,
                results: [ResultEnvelope] = [],
                aggregatesJSON: String? = nil) {
        self.id = id
        self.label = label
        self.conversationID = conversationID
        self.schedule = schedule
        self.repetitions = repetitions
        self.stateless = stateless
        self.orderSeed = orderSeed
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.results = results
        self.aggregatesJSON = aggregatesJSON
    }
}

/// Aggregates per backend over successful runs (errors excluded from averages).
public struct BackendAggregate: Codable, Sendable, Hashable {
    public var backend: BackendID
    public var modelID: String
    public var successes: Int
    public var failures: Int
    public var cancellations: Int
    public var ttftMS: Stats?
    public var wallMS: Stats?
    public var outputTokensPerSecond: Stats?
    public var medianOutputTokens: Double?
    public var tokenProvenance: TokenProvenance

    public struct Stats: Codable, Sendable, Hashable {
        public var median: Double?
        public var p95: Double?
        public var mean: Double?
        public var n: Int
    }
}

public enum AggregateBuilder {
    public static func build(run: BenchmarkRun) -> [BackendAggregate] {
        let backends = Set(run.results.map { $0.backend })
        var aggregates: [BackendAggregate] = []
        for backend in backends.sorted(by: { $0.rawValue < $1.rawValue }) {
            let results = run.results.filter { $0.backend == backend }
            let successes = results.filter { !$0.isError }
            let cancellations = results.filter { $0.isCancelled }
            let failures = results.count - successes.count - cancellations.count
            let identityModel = results.first?.modelID ?? "unknown"
            let provenance = results.first?.tokenProvenance ?? .unavailable
            aggregates.append(BackendAggregate(
                backend: backend,
                modelID: identityModel,
                successes: successes.count,
                failures: failures,
                cancellations: cancellations.count,
                ttftMS: stats(Metrics.successes(results) { $0.ttftMS }),
                wallMS: stats(Metrics.successes(results) { $0.wallMS }),
                outputTokensPerSecond: stats(Metrics.successes(results) { $0.outputTokensPerSecond }),
                medianOutputTokens: Metrics.median(successes.compactMap { $0.outputTokens.map(Double.init) }),
                tokenProvenance: provenance
            ))
        }
        return aggregates
    }

    static func stats(_ values: [Double]) -> BackendAggregate.Stats? {
        guard !values.isEmpty else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        return .init(median: Metrics.median(values), p95: Metrics.percentile(values, 95), mean: mean, n: values.count)
    }
}

/// Controls sequential/parallel scheduling, repetitions, backend ordering,
/// cold/warm labeling, and persistence of benchmark runs (spec §5). When a
/// store is attached, every request (including prewarm and failed/unavailable
/// attempts) is persisted live — conversation, turn, request envelope, result,
/// metric samples, and the full trace evidence set — so nothing is lost even
/// if the process dies mid-run.
public struct BenchmarkRunner: Sendable {
    public let backends: [BackendID: ChatBackend]
    public let recorder: MetricsRecorder
    public let store: SQLiteStore?
    public var onPersistenceError: (@Sendable (Error) -> Void)?

    public init(backends: [BackendID: ChatBackend], recorder: MetricsRecorder = MetricsRecorder(), store: SQLiteStore? = nil) {
        self.backends = backends
        self.recorder = recorder
        self.store = store
    }

    public struct Configuration: Sendable {
        public var prompt: String
        public var systemInstruction: String?
        public var schedule: RunSchedule
        public var repetitions: Int
        public var stateless: Bool
        public var alternateOrder: Bool
        public var orderSeed: String
        public var options: SamplingOptions
        public var passages: [ExtractedPassage]
        public var images: [PreparedImage]
        public var prewarm: Bool
        public var conversationID: String

        public init(prompt: String,
                    systemInstruction: String? = nil,
                    schedule: RunSchedule = .sequential,
                    repetitions: Int = 1,
                    stateless: Bool = false,
                    alternateOrder: Bool = true,
                    orderSeed: String = "default",
                    options: SamplingOptions = SamplingOptions(),
                    passages: [ExtractedPassage] = [],
                    images: [PreparedImage] = [],
                    prewarm: Bool = true,
                    conversationID: String = "benchmark-\(UUID().uuidString.prefix(8))") {
            self.prompt = prompt
            self.systemInstruction = systemInstruction
            self.schedule = schedule
            self.repetitions = max(1, repetitions)
            self.stateless = stateless
            self.alternateOrder = alternateOrder
            self.orderSeed = orderSeed
            self.options = options
            self.passages = passages
            self.images = images
            self.prewarm = prewarm
            self.conversationID = conversationID
        }
    }

    /// Deterministic ordering per repetition: alternates starting backend.
    static func order(for backends: [BackendID], repetition: Int, alternate: Bool) -> [BackendID] {
        guard backends.count > 1, alternate else { return backends }
        return repetition % 2 == 0 ? backends : Array(backends.reversed())
    }

    public func run(configuration: Configuration) async -> BenchmarkRun {
        var run = BenchmarkRun(
            label: configuration.prompt.prefix(48).replacingOccurrences(of: "\n", with: " "),
            conversationID: configuration.conversationID,
            schedule: configuration.schedule,
            repetitions: configuration.repetitions,
            stateless: configuration.stateless,
            orderSeed: configuration.orderSeed
        )
        let ids = Array(backends.keys).sorted { $0.rawValue < $1.rawValue }
        var warmthByBackend: [BackendID: Bool] = [:]

        if configuration.prewarm {
            // Prewarm pass: discard first-use artifacts and mark later runs warm.
            await prewarm(ids: ids)
        }

        for repetition in 0..<configuration.repetitions {
            let order = Self.order(for: ids, repetition: repetition, alternate: configuration.alternateOrder)
            if configuration.schedule == .sequential {
                for backendID in order {
                    guard let backend = backends[backendID] else { continue }
                    let envelope = Self.makeEnvelope(configuration: configuration, backend: backendID, repetition: repetition)
                    let warmth: WarmthLabel = (warmthByBackend[backendID] ?? false) ? .warm : .cold
                    warmthByBackend[backendID] = true
                    let report = await backend.availabilityReport()
                    guard report.isAvailable else {
                        let failed = unavailableResult(envelope: envelope, backend: backendID, report: report, repetition: repetition, warmth: warmth)
                        run.results.append(failed)
                        persist(envelope: envelope, backend: backendID, modelID: failed.modelID, identity: nil, result: failed, capture: selfTraceUnavailable(report: report))
                        continue
                    }
                    let sampler = MemorySampler()
                    let capture = self.capture(for: backendID)
                    let result = await recorder.record(
                        envelope: envelope,
                        backend: backendID,
                        modelID: report.identity?.modelID ?? backendID.rawValue,
                        identity: report.identity,
                        events: backend.stream(envelope, capture: capture),
                        repetitionIndex: repetition,
                        memorySampler: sampler,
                        capture: capture
                    )
                    var adjusted = result
                    adjusted.warmth = warmth
                    run.results.append(adjusted)
                    persist(envelope: envelope, backend: backendID, modelID: report.identity?.modelID ?? backendID.rawValue, identity: report.identity, result: adjusted, capture: capture)
                }
            } else {
                // Parallel: contended, UX-only per spec. Still recorded honestly.
                await withTaskGroup(of: ResultEnvelope.self) { group in
                    for backendID in order {
                        guard let backend = backends[backendID] else { continue }
                        let envelope = Self.makeEnvelope(configuration: configuration, backend: backendID, repetition: repetition)
                        group.addTask {
                            let sampler = MemorySampler()
                            let capture = self.capture(for: backendID)
                            let result = await self.recorder.record(
                                envelope: envelope,
                                backend: backendID,
                                modelID: backendID.rawValue,
                                identity: nil,
                                events: backend.stream(envelope, capture: capture),
                                repetitionIndex: repetition,
                                memorySampler: sampler,
                                capture: capture
                            )
                            var adjusted = result
                            adjusted.warmth = .warm // parallel always follows prewarm pass
                            self.persist(envelope: envelope, backend: backendID, modelID: backendID.rawValue, identity: nil, result: adjusted, capture: capture)
                            return adjusted
                        }
                    }
                    for await result in group {
                        run.results.append(result)
                    }
                }
            }
        }
        run.finishedAt = Date()
        let aggregates = AggregateBuilder.build(run: run)
        if let data = try? JSONEncoder().encode(aggregates) {
            run.aggregatesJSON = String(data: data, encoding: .utf8)
        }
        return run
    }

    func prewarm(ids: [BackendID]) async {
        for id in ids {
            guard let backend = backends[id] else { continue }
            let report = await backend.availabilityReport()
            guard report.isAvailable else { continue }
            let envelope = RequestEnvelope(
                conversationID: "prewarm",
                turnIndex: 0,
                canonicalUserText: "Warm up.",
                mode: .stateless,
                schedule: .sequential
            )
            let sampler = MemorySampler()
            let capture = capture(for: id)
            var result = await recorder.record(envelope: envelope, backend: id, modelID: report.identity?.modelID ?? id.rawValue, identity: report.identity, events: backend.stream(envelope, capture: capture), repetitionIndex: -1, memorySampler: sampler, capture: capture)
            result.warmth = .cold // prewarm IS the cold pass; discarded from aggregates, kept in the record
            persist(envelope: envelope, backend: id, modelID: report.identity?.modelID ?? id.rawValue, identity: report.identity, result: result, capture: capture)
        }
    }

    // MARK: Trace + persistence

    /// Fresh capture per request; Apple requests get an honest meta note that
    /// no wire protocol is user-accessible, so evidence is normalized-only.
    private func capture(for backendID: BackendID) -> StreamCapture {
        let capture = StreamCapture()
        if backendID == .apple {
            capture.append(kind: .meta, data: "Apple FoundationModels exposes no user-facing wire protocol; trace evidence is the normalized event stream only (recorded by MetricsRecorder). Raw request/response bytes are not accessible on this OS.")
        }
        return capture
    }

    /// Availability failures still persist a trace set so reviewers can see
    /// exactly why a backend produced no data.
    private func selfTraceUnavailable(report: AvailabilityReport) -> StreamCapture {
        let capture = StreamCapture()
        capture.append(kind: .meta, data: "backend unavailable before dispatch: \(report.reason) | advice: \(report.actionableAdvice)")
        return capture
    }

    /// Persist one request's full record: conversation, turn, request envelope,
    /// result, metric samples, and trace evidence. Failures are surfaced via
    /// `onPersistenceError` — never silently dropped, never fatal to measurement.
    private func persist(envelope: RequestEnvelope, backend: BackendID, modelID: String, identity: BackendIdentity?, result: ResultEnvelope, capture: StreamCapture) {
        guard let store else { return }
        do {
            let turnID = "turn-\(envelope.requestID)"
            try store.saveTurn(
                Turn(
                    id: turnID,
                    turnIndex: envelope.turnIndex,
                    canonicalUserText: envelope.canonicalUserText,
                    promptHash: envelope.promptHash,
                    schedule: envelope.schedule,
                    mode: envelope.mode
                ),
                conversationID: envelope.conversationID
            )
            try store.saveRequest(envelope: envelope, turnID: turnID, backend: backend)
            try store.saveResult(result)
            try store.saveMetricSamples(result.memorySamples, requestID: envelope.requestID)
            try store.saveTraces(capture.snapshot(), requestID: envelope.requestID)
            if let identity {
                try store.saveIdentity(identity)
            }
        } catch {
            onPersistenceError?(error)
        }
    }

    static func makeEnvelope(configuration: Configuration, backend: BackendID, repetition: Int) -> RequestEnvelope {
        RequestEnvelope(
            conversationID: configuration.conversationID,
            turnIndex: repetition,
            canonicalUserText: configuration.prompt,
            systemInstruction: configuration.systemInstruction,
            priorUserMessages: [],
            assistantHistory: [], // stateless benchmarks: no history
            extractedPassages: configuration.passages,
            attachmentSHA256s: configuration.passages.compactMap { $0.sha256 } + configuration.images.map { $0.sha256 },
            images: configuration.images,
            options: configuration.options,
            mode: configuration.stateless ? .stateless : .conversation,
            schedule: configuration.schedule
        )
    }

    func unavailableResult(envelope: RequestEnvelope, backend: BackendID, report: AvailabilityReport, repetition: Int, warmth: WarmthLabel) -> ResultEnvelope {
        let environment = AppEnvironment.current()
        let error = BackendError(kind: .unavailable, message: "\(backend.displayName) unavailable: \(report.reason)", underlying: report.actionableAdvice)
        return ResultEnvelope(
            requestID: envelope.requestID,
            conversationID: envelope.conversationID,
            turnIndex: envelope.turnIndex,
            backend: backend,
            modelID: report.identity?.modelID ?? backend.rawValue,
            osVersion: environment.osVersion,
            osBuild: environment.osBuild,
            dispatchMonotonicNS: 0,
            firstContentMonotonicNS: nil,
            endMonotonicNS: 0,
            ttftMS: nil,
            wallMS: 0,
            outputTokensPerSecond: nil,
            inputTokens: nil,
            outputTokens: nil,
            tokenProvenance: .unavailable,
            rawText: "",
            finishReason: .error,
            error: error,
            warmth: warmth,
            repetitionIndex: repetition,
            schedule: envelope.schedule,
            mode: envelope.mode,
            options: envelope.options,
            promptHash: envelope.promptHash,
            attachmentSHA256s: envelope.attachmentSHA256s
        )
    }
}
