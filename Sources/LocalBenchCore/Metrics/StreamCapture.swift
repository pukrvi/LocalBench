import Foundation

/// One piece of raw evidence: a verbatim wire record or a normalized event,
/// stamped with sequence, monotonic offset, byte count, and SHA-256 so that
/// every recorded metric can be independently recomputed from the trace alone
/// (spec §12: verifiable, no trust required).
public struct TraceRecord: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        /// The exact JSON body sent to LM Studio, before the HTTP write.
        case requestBody = "request_body"
        /// One verbatim SSE line as received (newline stripped; the line text
        /// itself is untouched, including the "data: " prefix).
        case sseLine = "sse_line"
        /// A normalized StreamEvent, JSON-encoded (both backends).
        case event = "event"
        /// Provenance note, e.g. "Apple has no wire access; normalized only".
        case meta = "meta"
    }

    public var seq: Int
    public var kind: Kind
    /// Milliseconds since the request's dispatch (capture clock is aligned to
    /// dispatch time by MetricsRecorder).
    public var offsetMS: Double
    public var byteCount: Int
    public var sha256: String
    public var data: String

    public init(seq: Int, kind: Kind, offsetMS: Double, byteCount: Int, sha256: String, data: String) {
        self.seq = seq
        self.kind = kind
        self.offsetMS = offsetMS
        self.byteCount = byteCount
        self.sha256 = sha256
        self.data = data
    }
}

/// Thread-safe per-request trace collector.
///
/// A capture is created per request; the backend records raw wire data into it,
/// MetricsRecorder records normalized events into it, and the completed record
/// set lands both in the SQLite store (`wire_traces`) and in the JSON export
/// (embedded in `ResultEnvelope.traces`). Reviewers recompute metrics with
/// `localbench verify --db PATH` without trusting the recording process.
public final class StreamCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [TraceRecord] = []
    private var startedNS = Metrics.nowMonotonicNS()

    public init() {}

    /// Re-anchor the capture clock to "now" (MetricsRecorder does this at
    /// dispatch so offsets are directly comparable to ttft/wall).
    public func resetClock() {
        lock.lock()
        defer { lock.unlock() }
        startedNS = Metrics.nowMonotonicNS()
    }

    public func append(kind: TraceRecord.Kind, data: String) {
        lock.lock()
        let offsetMS = Double(Metrics.nowMonotonicNS() &- startedNS) / 1_000_000
        let record = TraceRecord(
            seq: records.count,
            kind: kind,
            offsetMS: offsetMS,
            byteCount: data.utf8.count,
            sha256: Sha256.hex(data),
            data: data
        )
        records.append(record)
        lock.unlock()
    }

    public func snapshot() -> [TraceRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }

    /// Chained hash over every record's own hash — one fingerprint that pins
    /// the entire evidence set for a request.
    public func fingerprint() -> String {
        lock.lock()
        defer { lock.unlock() }
        return Sha256.hex(records.map { $0.sha256 }.joined(separator: "\n"))
    }
}
