import Foundation

/// Read-side queries for the GUI dashboard and trace browser.
extension SQLiteStore {
    public struct RunSummary: Sendable, Hashable, Identifiable {
        public var id: String
        public var label: String
        public var schedule: String
        public var repetitions: Int
        public var stateless: Bool
        public var startedAt: Date
        public var finishedAt: Date?
        public var conversationID: String?
        public var resultCount: Int
    }

    /// All persisted benchmark runs, newest first.
    public func benchmarkRunSummaries() throws -> [RunSummary] {
        var summaries: [RunSummary] = []
        try query(
            """
            SELECT b.id, b.label, b.schedule, b.repetitions, b.stateless, b.started_at, b.finished_at, b.conversation_id,
                   (SELECT COUNT(*) FROM requests r JOIN turns t ON t.id = r.turn_id
                    WHERE t.conversation_id = b.conversation_id)
            FROM benchmark_runs b
            ORDER BY b.started_at DESC
            """
        ) { row in
            summaries.append(RunSummary(
                id: row.text(0) ?? "",
                label: row.text(1) ?? "",
                schedule: row.text(2) ?? "",
                repetitions: row.int(3) ?? 0,
                stateless: (row.int(4) ?? 0) == 1,
                startedAt: Date(timeIntervalSince1970: row.double(5) ?? 0),
                finishedAt: row.double(6).map { Date(timeIntervalSince1970: $0) },
                conversationID: row.text(7),
                resultCount: row.int(8) ?? 0
            ))
        }
        return summaries
    }

    /// Results belonging to a benchmark run (linked through the run's conversation).
    public func results(conversationID: String) throws -> [ResultEnvelope] {
        var results: [ResultEnvelope] = []
        try query(
            """
            SELECT res.request_id, res.backend, res.model_id, res.os_version, res.os_build,
                   res.ttft_ms, res.wall_ms, res.output_tokens_per_second, res.prefill_tokens_per_second,
                   res.input_tokens, res.output_tokens, res.cached_tokens, res.reasoning_tokens, res.token_provenance,
                   res.peak_footprint_mb, res.system_peak_pressure, res.memory_scope, res.raw_text,
                   res.error_kind, res.error_message, res.finish_reason, res.warmth, res.repetition_index,
                   res.schedule, res.mode, res.options_json, res.prompt_hash, res.attachment_hashes_json,
                   res.backend_settings_json, res.created_at
            FROM results res
            JOIN requests req ON req.id = res.request_id
            JOIN turns t ON t.id = req.turn_id
            WHERE t.conversation_id = ?
            ORDER BY res.repetition_index, res.backend
            """,
            bind: [.text(conversationID)]
        ) { row in
            if let envelope = Self.resultEnvelope(from: row, conversationID: conversationID) {
                results.append(envelope)
            }
        }
        return results
    }

    /// Rebuilds a ResultEnvelope from a `results` row (traces fetched separately).
    public static func resultEnvelope(from row: StatementRow, conversationID: String = "") -> ResultEnvelope? {
        guard let requestID = row.text(0),
              let backendRaw = row.text(1),
              let backend = BackendID(rawValue: backendRaw) else { return nil }
        let modelID = row.text(2) ?? backendRaw
        let repetition = row.int(22) ?? 0
        let optionsJSON = row.text(25)
        var options = SamplingOptions()
        if let optionsJSON, let data = optionsJSON.data(using: .utf8) {
            options = (try? JSONDecoder().decode(SamplingOptions.self, from: data)) ?? options
        }
        var attachments: [String] = []
        if let hashesJSON = row.text(27), let data = hashesJSON.data(using: .utf8) {
            attachments = (try? JSONDecoder().decode([String].self, from: data)) ?? []
        }
        let errorKind = row.text(18)
        let error: BackendError? = errorKind.map { kindRaw in
            BackendError(
                kind: BackendError.Kind(rawValue: kindRaw) ?? .unknown,
                message: row.text(19) ?? "recorded error"
            )
        }
        return ResultEnvelope(
            requestID: requestID,
            conversationID: conversationID,
            turnIndex: repetition,
            backend: backend,
            modelID: modelID,
            osVersion: row.text(3) ?? "unknown",
            osBuild: row.text(4) ?? "unknown",
            dispatchMonotonicNS: 0,
            firstContentMonotonicNS: nil,
            endMonotonicNS: 0,
            ttftMS: row.double(5),
            wallMS: row.double(6) ?? 0,
            outputTokensPerSecond: row.double(7),
            prefillTokensPerSecond: row.double(8),
            inputTokens: row.int(9),
            outputTokens: row.int(10),
            cachedTokens: row.int(11),
            reasoningTokens: row.int(12),
            tokenProvenance: TokenProvenance(rawValue: row.text(13) ?? "") ?? .unavailable,
            peakProcessFootprintMB: row.double(14),
            systemPeakPressureLevel: row.int(15),
            memoryScopeNote: row.text(16) ?? "",
            memorySamples: [],
            rawText: row.text(17) ?? "",
            finishReason: FinishReason(rawValue: row.text(20) ?? "") ?? .unknown,
            error: error,
            warmth: WarmthLabel(rawValue: row.text(21) ?? "") ?? .unknown,
            repetitionIndex: repetition,
            schedule: RunSchedule(rawValue: row.text(23) ?? "") ?? .sequential,
            mode: RunMode(rawValue: row.text(24) ?? "") ?? .conversation,
            options: options,
            promptHash: row.text(26) ?? "",
            attachmentSHA256s: attachments,
            traces: [],
            tracesFingerprint: "",
            backendSettingsJSON: row.text(28) ?? "{}"
        )
    }

    /// Number of evidence records stored for one request (0 = none).
    public func traceCount(requestID: String) throws -> Int {
        var count = 0
        try query("SELECT COUNT(*) FROM wire_traces WHERE request_id = ?", bind: [.text(requestID)]) { row in
            count = row.int(0) ?? 0
        }
        return count
    }
}
