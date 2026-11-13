import Foundation

/// Produces local CSV/JSON artifacts (spec §1, §12). Every export includes
/// prompt hash, attachment hashes, model identity, run mode, settings,
/// OS/hardware, units, and provenance.
public enum ExportService {
    // MARK: JSON

    public struct JSONExport: Codable {
        public var formatVersion: String
        public var exportedAt: Date
        public var environment: AppEnvironmentSnapshot
        public var run: BenchmarkRun
        public var aggregates: [BackendAggregate]
        public var units: Units
        public var provenanceNotes: [String]

        public struct Units: Codable {
            public var time: String
            public var tokensPerSecond: String
            public var memory: String
            public var tokens: String
        }

        public init(formatVersion: String = "1.0",
                    exportedAt: Date = Date(),
                    environment: AppEnvironmentSnapshot,
                    run: BenchmarkRun,
                    aggregates: [BackendAggregate]) {
            self.formatVersion = formatVersion
            self.exportedAt = exportedAt
            self.environment = environment
            self.run = run
            self.aggregates = aggregates
            self.units = Units(time: "milliseconds (wall clock, monotonic deltas)", tokensPerSecond: "tokens/second", memory: "MB phys_footprint", tokens: "tokens (provenance per row)")
            self.provenanceNotes = [
                "ttft_ms = first nonempty generated content time − dispatch time; includes queue/prefill, not pure model prefill",
                "decode tokens/sec ≈ output tokens ÷ (end − first content); approximate unless token count provenance is native/server",
                "prefill tokens per second omitted: no trustworthy prefill timing is exposed by either backend",
                "process footprint is NOT model RAM for the system-hosted Apple backend; memory samples are labeled by scope",
                "cancelled/failed runs are recorded but excluded from median/p95/mean of successes",
                "on-device only: Apple backend uses SystemLanguageModel.default; LM Studio traffic bound to loopback",
                "full trace evidence is embedded per result (result.traces) and persisted to SQLite (wire_traces): LM Studio stores the exact request body JSON plus every verbatim SSE line, each with offset/byte-count/sha256; Apple has no user-facing wire protocol, so its evidence is the normalized event stream plus an explicit meta note",
                "independent verification: recompute TTFT/wall/tokens from the raw evidence with `localbench verify --db PATH` — no metric has to be taken on trust"
            ]
        }
    }

    public static func json(for run: BenchmarkRun) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let export = JSONExport(
            environment: AppEnvironment.current(),
            run: run,
            aggregates: AggregateBuilder.build(run: run)
        )
        return try encoder.encode(export)
    }

    // MARK: CSV

    public static let csvHeader = [
        "run_id", "repetition", "backend", "model_id", "schedule", "mode", "warmth",
        "ttft_ms", "wall_ms", "decode_tokens_per_second",
        "input_tokens", "output_tokens", "cached_tokens", "reasoning_tokens", "token_provenance",
        "peak_footprint_mb", "memory_scope",
        "finish_reason", "error_kind", "error_message",
        "prompt_hash", "attachment_hashes", "os_version", "os_build",
        "dispatch_mono_ns", "first_content_mono_ns", "end_mono_ns",
        "trace_records", "trace_fingerprint",
    ]

    public static func csv(for run: BenchmarkRun) -> String {
        var lines = [csvHeader.joined(separator: ",")]
        for result in run.results.sorted(by: { $0.repetitionIndex < $1.repetitionIndex }) {
            let row: [String] = [
                run.id,
                String(result.repetitionIndex),
                result.backend.rawValue,
                result.modelID,
                result.schedule.rawValue,
                result.mode.rawValue,
                result.warmth.rawValue,
                optional(result.ttftMS),
                fixed(result.wallMS),
                optional(result.outputTokensPerSecond),
                optional(result.inputTokens),
                optional(result.outputTokens),
                optional(result.cachedTokens),
                optional(result.reasoningTokens),
                result.tokenProvenance.rawValue,
                optional(result.peakProcessFootprintMB),
                result.memoryScopeNote,
                result.finishReason.rawValue,
                result.error?.kind.rawValue ?? "",
                result.error?.message ?? "",
                result.promptHash,
                result.attachmentSHA256s.joined(separator: ";"),
                result.osVersion,
                result.osBuild,
                String(result.dispatchMonotonicNS),
                optional(result.firstContentMonotonicNS),
                String(result.endMonotonicNS),
                String(result.traces.count),
                result.tracesFingerprint,
            ]
            lines.append(row.map(csvEscape).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func csvEscape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }

    static func optional(_ value: Int?) -> String { value.map(String.init) ?? "n/a" }
    static func optional(_ value: Double?) -> String { value.map { String(format: "%.2f", $0) } ?? "n/a" }
    static func fixed(_ value: Double) -> String { String(format: "%.2f", value) }
    static func optional(_ value: UInt64?) -> String { value.map(String.init) ?? "n/a" }

    /// Write both artifacts to a directory; returns file paths.
    public static func write(run: BenchmarkRun, to directory: URL, fileBaseName: String = "localbench-run") throws -> (json: URL, csv: URL) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let jsonURL = directory.appendingPathComponent("\(fileBaseName).json")
        let csvURL = directory.appendingPathComponent("\(fileBaseName).csv")
        try Data(json(for: run)).write(to: jsonURL)
        try Data(csv(for: run).utf8).write(to: csvURL)
        return (jsonURL, csvURL)
    }
}
