import Foundation

/// Normalized stream events emitted identically by both backends.
/// Codable: encoded verbatim into trace records for independent verification.
public enum StreamEvent: Codable, Sendable {
    case started(backend: BackendID, at: Date)
    case delta(backend: BackendID, text: String)
    /// Token counts with their provenance; emitted as soon as known.
    case usage(backend: BackendID, inputTokens: Int?, outputTokens: Int?, cachedTokens: Int?, reasoningTokens: Int?, provenance: TokenProvenance)
    case finished(backend: BackendID, reason: FinishReason, at: Date)
    case failed(backend: BackendID, error: BackendError, at: Date)
}

/// A backend error with enough structure to record honestly.
public struct BackendError: Error, Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable {
        case unavailable          // Apple Intelligence off, LM Studio offline, model not loaded
        case network              // connection refused/reset (loopback only)
        case malformedResponse    // bad SSE, bad JSON
        case timeout
        case cancelled
        case contextTooLong
        case unsupportedCapability // images on text-only model, etc.
        case serverError
        case unknown
    }

    public var kind: Kind
    public var message: String
    public var underlying: String?

    public init(kind: Kind, message: String, underlying: String? = nil) {
        self.kind = kind
        self.message = message
        self.underlying = underlying
    }

    public static func cancelled() -> BackendError {
        BackendError(kind: .cancelled, message: "Cancelled by user")
    }

    public var finishReason: FinishReason {
        switch kind {
        case .cancelled: return .cancelled
        case .timeout: return .error
        default: return .error
        }
    }
}

/// Memory samples taken during a run. Scope is always recorded: a process
/// footprint is NOT model RAM for the system-hosted Apple backend (spec §6).
public struct MemorySample: Codable, Sendable, Hashable {
    public var offsetMS: Double
    public var processFootprintMB: Double?
    public var systemFreePagesMB: Double?
    public var systemPressureLevel: Int?
    public var scopeNote: String

    public init(offsetMS: Double,
                processFootprintMB: Double?,
                systemFreePagesMB: Double?,
                systemPressureLevel: Int?,
                scopeNote: String) {
        self.offsetMS = offsetMS
        self.processFootprintMB = processFootprintMB
        self.systemFreePagesMB = systemFreePagesMB
        self.systemPressureLevel = systemPressureLevel
        self.scopeNote = scopeNote
    }
}

/// Final, normalized measurement of one backend's response to one request.
public struct ResultEnvelope: Codable, Sendable, Hashable {
    public var requestID: String
    public var conversationID: String
    public var turnIndex: Int
    public var backend: BackendID
    public var modelID: String
    public var osVersion: String
    public var osBuild: String

    public var dispatchMonotonicNS: UInt64
    public var firstContentMonotonicNS: UInt64?
    public var endMonotonicNS: UInt64

    public var ttftMS: Double?
    public var wallMS: Double
    public var outputTokensPerSecond: Double?
    /// Only when a backend exposes trustworthy prefill timing; always nil today.
    public var prefillTokensPerSecond: Double?

    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cachedTokens: Int?
    public var reasoningTokens: Int?
    public var tokenProvenance: TokenProvenance

    public var peakProcessFootprintMB: Double?
    public var systemPeakPressureLevel: Int?
    public var memoryScopeNote: String
    public var memorySamples: [MemorySample]

    public var rawText: String
    public var finishReason: FinishReason
    public var error: BackendError?
    public var warmth: WarmthLabel
    public var repetitionIndex: Int
    public var schedule: RunSchedule
    public var mode: RunMode
    public var options: SamplingOptions
    public var promptHash: String
    public var attachmentSHA256s: [String]
    public var backendSettingsJSON: String

    /// Raw evidence for this request (wire captures + normalized events), embedded
    /// so JSON exports are self-contained; also persisted to `wire_traces`.
    public var traces: [TraceRecord]
    /// Chained SHA-256 over `traces` — one hash pinning the whole evidence set.
    public var tracesFingerprint: String

    public var isError: Bool { error != nil }
    public var isCancelled: Bool { error?.kind == .cancelled }

    public init(requestID: String,
                conversationID: String,
                turnIndex: Int,
                backend: BackendID,
                modelID: String,
                osVersion: String,
                osBuild: String,
                dispatchMonotonicNS: UInt64,
                firstContentMonotonicNS: UInt64?,
                endMonotonicNS: UInt64,
                ttftMS: Double?,
                wallMS: Double,
                outputTokensPerSecond: Double?,
                prefillTokensPerSecond: Double? = nil,
                inputTokens: Int? = nil,
                outputTokens: Int? = nil,
                cachedTokens: Int? = nil,
                reasoningTokens: Int? = nil,
                tokenProvenance: TokenProvenance = .unavailable,
                peakProcessFootprintMB: Double? = nil,
                systemPeakPressureLevel: Int? = nil,
                memoryScopeNote: String = "",
                memorySamples: [MemorySample] = [],
                rawText: String = "",
                finishReason: FinishReason = .unknown,
                error: BackendError? = nil,
                warmth: WarmthLabel = .unknown,
                repetitionIndex: Int = 0,
                schedule: RunSchedule = .sequential,
                mode: RunMode = .conversation,
                options: SamplingOptions = SamplingOptions(),
                promptHash: String = "",
                attachmentSHA256s: [String] = [],
                traces: [TraceRecord] = [],
                tracesFingerprint: String = "",
                backendSettingsJSON: String = "{}") {
        self.requestID = requestID
        self.conversationID = conversationID
        self.turnIndex = turnIndex
        self.backend = backend
        self.modelID = modelID
        self.osVersion = osVersion
        self.osBuild = osBuild
        self.dispatchMonotonicNS = dispatchMonotonicNS
        self.firstContentMonotonicNS = firstContentMonotonicNS
        self.endMonotonicNS = endMonotonicNS
        self.ttftMS = ttftMS
        self.wallMS = wallMS
        self.outputTokensPerSecond = outputTokensPerSecond
        self.prefillTokensPerSecond = prefillTokensPerSecond
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedTokens = cachedTokens
        self.reasoningTokens = reasoningTokens
        self.tokenProvenance = tokenProvenance
        self.peakProcessFootprintMB = peakProcessFootprintMB
        self.systemPeakPressureLevel = systemPeakPressureLevel
        self.memoryScopeNote = memoryScopeNote
        self.memorySamples = memorySamples
        self.rawText = rawText
        self.finishReason = finishReason
        self.error = error
        self.warmth = warmth
        self.repetitionIndex = repetitionIndex
        self.schedule = schedule
        self.mode = mode
        self.options = options
        self.promptHash = promptHash
        self.attachmentSHA256s = attachmentSHA256s
        self.traces = traces
        self.tracesFingerprint = tracesFingerprint
        self.backendSettingsJSON = backendSettingsJSON
    }
}

/// A conversation with per-backend isolated assistant outputs.
public struct Conversation: Codable, Sendable, Hashable {
    public var id: String
    public var title: String
    public var createdAt: Date
    public var turns: [Turn]

    public init(id: String = UUID().uuidString, title: String, createdAt: Date = Date(), turns: [Turn] = []) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.turns = turns
    }
}

public struct Turn: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var turnIndex: Int
    public var canonicalUserText: String
    public var promptHash: String
    public var records: [BackendID: TurnRecord]
    public var schedule: RunSchedule
    public var mode: RunMode
    public var createdAt: Date

    public init(id: String = UUID().uuidString,
                turnIndex: Int,
                canonicalUserText: String,
                promptHash: String = "",
                records: [BackendID: TurnRecord] = [:],
                schedule: RunSchedule = .sequential,
                mode: RunMode = .conversation,
                createdAt: Date = Date()) {
        self.id = id
        self.turnIndex = turnIndex
        self.canonicalUserText = canonicalUserText
        self.promptHash = promptHash
        self.records = records
        self.schedule = schedule
        self.mode = mode
        self.createdAt = createdAt
    }
}

/// One backend's record for a turn: streamed text, final result, errors.
public struct TurnRecord: Codable, Sendable, Hashable {
    public var backend: BackendID
    public var streamedText: String
    public var result: ResultEnvelope?
    public var identity: BackendIdentity?

    public init(backend: BackendID, streamedText: String = "", result: ResultEnvelope? = nil, identity: BackendIdentity? = nil) {
        self.backend = backend
        self.streamedText = streamedText
        self.result = result
        self.identity = identity
    }
}
