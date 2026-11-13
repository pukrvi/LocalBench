import Foundation
import SQLite3

/// SQLite persistence (spec §9): conversations, turns, attachments, passages,
/// model configs, requests, results, sampled stream events, metric samples,
/// evaluations, benchmark runs, app environment. WAL + foreign keys + migrations.
public final class SQLiteStore: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = NSLock()

    public enum StoreError: Error, Sendable {
        case openFailed(String)
        case execFailed(String)
        case prepareFailed(String)
        case stepFailed(String)
    }

    public init(path: String) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let db { sqlite3_close(db) }
            throw StoreError.openFailed(message)
        }
        handle = db
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA foreign_keys=ON")
        try migrate()
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    public static func inMemory() throws -> SQLiteStore {
        try SQLiteStore(path: ":memory:")
    }

    // MARK: Schema

    static let schemaVersion = 2

    static let ddl: [String] = [
        """
        CREATE TABLE IF NOT EXISTS conversations (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            created_at REAL NOT NULL
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS turns (
            id TEXT PRIMARY KEY,
            conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
            turn_index INTEGER NOT NULL,
            canonical_user_text TEXT NOT NULL,
            canonical_prompt_sha256 TEXT NOT NULL,
            schedule TEXT NOT NULL,
            mode TEXT NOT NULL,
            created_at REAL NOT NULL,
            UNIQUE(conversation_id, turn_index)
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS attachments (
            id TEXT PRIMARY KEY,
            turn_id TEXT NOT NULL REFERENCES turns(id) ON DELETE CASCADE,
            filename TEXT NOT NULL,
            kind TEXT NOT NULL,
            sha256 TEXT NOT NULL,
            byte_size INTEGER NOT NULL,
            local_path TEXT,
            page_count INTEGER,
            ocr_used INTEGER NOT NULL DEFAULT 0,
            created_at REAL NOT NULL
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS extracted_passages (
            id TEXT PRIMARY KEY,
            attachment_id TEXT NOT NULL REFERENCES attachments(id) ON DELETE CASCADE,
            document_name TEXT NOT NULL,
            page_number INTEGER,
            char_offset INTEGER NOT NULL,
            char_length INTEGER NOT NULL,
            text TEXT NOT NULL,
            injected INTEGER NOT NULL DEFAULT 0
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS model_configs (
            id TEXT PRIMARY KEY,
            backend TEXT NOT NULL,
            model_id TEXT NOT NULL,
            display_name TEXT,
            context_size INTEGER,
            capabilities_json TEXT,
            captured_at REAL NOT NULL
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS requests (
            id TEXT PRIMARY KEY,
            turn_id TEXT NOT NULL REFERENCES turns(id) ON DELETE CASCADE,
            backend TEXT NOT NULL,
            envelope_json TEXT NOT NULL,
            created_at REAL NOT NULL,
            UNIQUE(turn_id, backend)
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS results (
            request_id TEXT PRIMARY KEY REFERENCES requests(id) ON DELETE CASCADE,
            backend TEXT NOT NULL,
            model_id TEXT NOT NULL,
            os_version TEXT,
            os_build TEXT,
            ttft_ms REAL,
            wall_ms REAL NOT NULL,
            output_tokens_per_second REAL,
            prefill_tokens_per_second REAL,
            input_tokens INTEGER,
            output_tokens INTEGER,
            cached_tokens INTEGER,
            reasoning_tokens INTEGER,
            token_provenance TEXT NOT NULL,
            peak_footprint_mb REAL,
            system_peak_pressure INTEGER,
            memory_scope TEXT,
            raw_text TEXT,
            error_kind TEXT,
            error_message TEXT,
            finish_reason TEXT,
            warmth TEXT,
            repetition_index INTEGER NOT NULL DEFAULT 0,
            schedule TEXT,
            mode TEXT,
            options_json TEXT,
            prompt_hash TEXT,
            attachment_hashes_json TEXT,
            backend_settings_json TEXT,
            created_at REAL NOT NULL
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS stream_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            request_id TEXT NOT NULL REFERENCES requests(id) ON DELETE CASCADE,
            backend TEXT NOT NULL,
            event TEXT NOT NULL,
            payload_json TEXT,
            offset_ms REAL NOT NULL,
            sampled INTEGER NOT NULL DEFAULT 1
        );
        """,
        """
        -- Raw evidence for independent verification: verbatim wire captures and
        -- normalized events, hash-stamped per record. Recompute metrics with
        -- TraceVerifier (`localbench verify --db PATH`).
        CREATE TABLE IF NOT EXISTS wire_traces (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            request_id TEXT NOT NULL REFERENCES requests(id) ON DELETE CASCADE,
            seq INTEGER NOT NULL,
            kind TEXT NOT NULL,
            offset_ms REAL NOT NULL,
            byte_count INTEGER NOT NULL,
            sha256 TEXT NOT NULL,
            data TEXT NOT NULL,
            UNIQUE(request_id, seq)
        );
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_wire_traces_request ON wire_traces(request_id, seq);
        """,
        """
        CREATE TABLE IF NOT EXISTS metric_samples (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            request_id TEXT NOT NULL REFERENCES requests(id) ON DELETE CASCADE,
            offset_ms REAL NOT NULL,
            footprint_mb REAL,
            system_free_mb REAL,
            pressure_level INTEGER,
            scope TEXT NOT NULL
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS benchmark_runs (
            id TEXT PRIMARY KEY,
            conversation_id TEXT,
            label TEXT,
            schedule TEXT NOT NULL,
            repetitions INTEGER NOT NULL,
            stateless INTEGER NOT NULL,
            order_seed TEXT,
            started_at REAL NOT NULL,
            finished_at REAL,
            aggregates_json TEXT
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS evaluations (
            id TEXT PRIMARY KEY,
            request_id TEXT NOT NULL REFERENCES requests(id) ON DELETE CASCADE,
            backend TEXT NOT NULL,
            thumbs INTEGER,
            rubric_json TEXT,
            judged_by TEXT,
            created_at REAL NOT NULL
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS app_environment (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            os_version TEXT,
            os_build TEXT,
            chip TEXT,
            cpu_cores INTEGER,
            memory_gb REAL,
            thermal_state TEXT,
            low_power INTEGER,
            battery TEXT,
            captured_at REAL NOT NULL
        );
        """,
        """
        CREATE VIRTUAL TABLE IF NOT EXISTS passages_fts USING fts5(
            text, passage_id UNINDEXED
        );
        """,
    ]

    private func migrate() throws {
        let current = (try? scalar("PRAGMA user_version").flatMap { Int($0) }) ?? 0
        if current < Self.schemaVersion {
            for statement in Self.ddl {
                try execute(statement)
            }
            try execute("PRAGMA user_version=\(Self.schemaVersion)")
        }
    }

    // MARK: Low-level helpers

    func execute(_ sql: String, bind: [SQLValue] = []) throws {
        lock.lock()
        defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.prepareFailed(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        try bindValues(bind, to: statement)
        // PRAGMAs such as journal_mode=WAL return a result row; that is still
        // a successful execution. Only real step failures throw.
        let stepResult = sqlite3_step(statement)
        guard stepResult == SQLITE_DONE || stepResult == SQLITE_ROW else {
            throw StoreError.execFailed(String(cString: sqlite3_errmsg(handle)))
        }
    }

    public func scalar(_ sql: String, bind: [SQLValue] = []) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.prepareFailed(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        try bindValues(bind, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let type = sqlite3_column_type(statement, 0)
        if type == SQLITE_NULL { return nil }
        return String(cString: sqlite3_column_text(statement, 0))
    }

    public func query(_ sql: String, bind: [SQLValue] = [], row: @escaping (StatementRow) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.prepareFailed(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        try bindValues(bind, to: statement)
        while sqlite3_step(statement) == SQLITE_ROW {
            row(StatementRow(statement: statement))
        }
    }

    private func bindValues(_ values: [SQLValue], to statement: OpaquePointer?) throws {
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case .text(let string):
                sqlite3_bind_text(statement, position, string, -1, SQLITE_TRANSIENT)
            case .int(let integer):
                sqlite3_bind_int64(statement, position, Int64(integer))
            case .real(let double):
                sqlite3_bind_double(statement, position, double)
            case .null:
                sqlite3_bind_null(statement, position)
            }
        }
    }

    public func runInTransaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
}

public enum SQLValue: Sendable {
    case text(String)
    case int(Int)
    case real(Double)
    case null
}

/// SQLITE_TRANSIENT is a C macro not imported into Swift.
let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Read-only view over a statement's current row.
public struct StatementRow {
    let statement: OpaquePointer?

    public func text(_ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return String(cString: sqlite3_column_text(statement, column))
    }

    public func int(_ column: Int32) -> Int? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(statement, column))
    }

    public func double(_ column: Int32) -> Double? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(statement, column)
    }
}

// MARK: - Typed persistence API

extension SQLiteStore {
    /// Upsert a conversation. `overwriteTitle: false` is used by `saveTurn`'s
    /// auto-create so it never clobbers a user-set title.
    ///
    /// IMPORTANT: this must be a true upsert (`ON CONFLICT DO UPDATE`), NOT
    /// `INSERT OR REPLACE` — REPLACE deletes the existing parent row first,
    /// which fires ON DELETE CASCADE and silently wipes all child turns,
    /// requests, results, and trace evidence.
    public func saveConversation(_ conversation: Conversation, overwriteTitle: Bool = true) throws {
        if overwriteTitle {
            try execute(
                "INSERT INTO conversations (id, title, created_at) VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET title = excluded.title",
                bind: [.text(conversation.id), .text(conversation.title), .real(conversation.createdAt.timeIntervalSince1970)]
            )
        } else {
            try execute(
                "INSERT OR IGNORE INTO conversations (id, title, created_at) VALUES (?, ?, ?)",
                bind: [.text(conversation.id), .text(conversation.title), .real(conversation.createdAt.timeIntervalSince1970)]
            )
        }
    }

    public func saveTurn(_ turn: Turn, conversationID: String) throws {
        try saveConversation(Conversation(id: conversationID, title: "auto"), overwriteTitle: false)
        try execute(
            """
            INSERT INTO turns (id, conversation_id, turn_index, canonical_user_text, canonical_prompt_sha256, schedule, mode, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                conversation_id = excluded.conversation_id,
                turn_index = excluded.turn_index,
                canonical_user_text = excluded.canonical_user_text,
                canonical_prompt_sha256 = excluded.canonical_prompt_sha256,
                schedule = excluded.schedule,
                mode = excluded.mode
            """,
            bind: [
                .text(turn.id), .text(conversationID), .int(turn.turnIndex),
                .text(turn.canonicalUserText), .text(turn.promptHash),
                .text(turn.schedule.rawValue), .text(turn.mode.rawValue),
                .real(turn.createdAt.timeIntervalSince1970),
            ]
        )
    }

    /// Non-destructive upsert: `INSERT OR REPLACE` here would cascade-delete
    /// the request's results and wire traces on every re-save.
    public func saveRequest(envelope: RequestEnvelope, turnID: String, backend: BackendID) throws {
        let json = JSONCoding.encode(envelope)
        try execute(
            """
            INSERT INTO requests (id, turn_id, backend, envelope_json, created_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                turn_id = excluded.turn_id,
                backend = excluded.backend,
                envelope_json = excluded.envelope_json
            """,
            bind: [.text(envelope.requestID), .text(turnID), .text(backend.rawValue), .text(json), .real(envelope.createdAt.timeIntervalSince1970)]
        )
    }

    public func saveResult(_ result: ResultEnvelope) throws {
        try execute(
            """
            INSERT OR REPLACE INTO results (
                request_id, backend, model_id, os_version, os_build,
                ttft_ms, wall_ms, output_tokens_per_second, prefill_tokens_per_second,
                input_tokens, output_tokens, cached_tokens, reasoning_tokens, token_provenance,
                peak_footprint_mb, system_peak_pressure, memory_scope,
                raw_text, error_kind, error_message, finish_reason, warmth,
                repetition_index, schedule, mode, options_json, prompt_hash,
                attachment_hashes_json, backend_settings_json, created_at
            ) VALUES (
                ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
            )
            """,
            bind: [
                .text(result.requestID), .text(result.backend.rawValue), .text(result.modelID),
                .text(result.osVersion), .text(result.osBuild),
                result.ttftMS.map { .real($0) } ?? .null,
                .real(result.wallMS),
                result.outputTokensPerSecond.map { .real($0) } ?? .null,
                result.prefillTokensPerSecond.map { .real($0) } ?? .null,
                result.inputTokens.map { .int($0) } ?? .null,
                result.outputTokens.map { .int($0) } ?? .null,
                result.cachedTokens.map { .int($0) } ?? .null,
                result.reasoningTokens.map { .int($0) } ?? .null,
                .text(result.tokenProvenance.rawValue),
                result.peakProcessFootprintMB.map { .real($0) } ?? .null,
                result.systemPeakPressureLevel.map { .int($0) } ?? .null,
                .text(result.memoryScopeNote),
                .text(result.rawText),
                result.error.map { .text($0.kind.rawValue) } ?? .null,
                result.error.map { .text($0.message) } ?? .null,
                .text(result.finishReason.rawValue),
                .text(result.warmth.rawValue),
                .int(result.repetitionIndex),
                .text(result.schedule.rawValue),
                .text(result.mode.rawValue),
                .text(JSONCoding.encode(result.options)),
                .text(result.promptHash),
                .text(JSONCoding.encode(result.attachmentSHA256s)),
                .text(result.backendSettingsJSON),
                .real(Date().timeIntervalSince1970),
            ]
        )
    }

    public func saveMetricSamples(_ samples: [MemorySample], requestID: String) throws {
        for sample in samples {
            try execute(
                """
                INSERT INTO metric_samples (request_id, offset_ms, footprint_mb, system_free_mb, pressure_level, scope)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                bind: [
                    .text(requestID), .real(sample.offsetMS),
                    sample.processFootprintMB.map { .real($0) } ?? .null,
                    sample.systemFreePagesMB.map { .real($0) } ?? .null,
                    sample.systemPressureLevel.map { .int($0) } ?? .null,
                    .text(sample.scopeNote),
                ]
            )
        }
    }

    /// Persist a request's full evidence set (raw wire captures + normalized
    /// events). Replaces any previous rows for the request, so re-saving the
    /// same result is idempotent.
    public func saveTraces(_ records: [TraceRecord], requestID: String) throws {
        try runInTransaction {
            try self.execute("DELETE FROM wire_traces WHERE request_id = ?", bind: [.text(requestID)])
            for record in records {
                try self.execute(
                    """
                    INSERT INTO wire_traces (request_id, seq, kind, offset_ms, byte_count, sha256, data)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    bind: [
                        .text(requestID), .int(record.seq), .text(record.kind.rawValue),
                        .real(record.offsetMS), .int(record.byteCount), .text(record.sha256), .text(record.data),
                    ]
                )
            }
        }
    }

    public func wireTraces(requestID: String) throws -> [TraceRecord] {
        var records: [TraceRecord] = []
        try query(
            "SELECT seq, kind, offset_ms, byte_count, sha256, data FROM wire_traces WHERE request_id = ? ORDER BY seq",
            bind: [.text(requestID)]
        ) { row in
            guard let kindRaw = row.text(1), let kind = TraceRecord.Kind(rawValue: kindRaw) else { return }
            records.append(TraceRecord(
                seq: row.int(0) ?? 0,
                kind: kind,
                offsetMS: row.double(2) ?? 0,
                byteCount: row.int(3) ?? 0,
                sha256: row.text(4) ?? "",
                data: row.text(5) ?? ""
            ))
        }
        return records
    }

    public func saveStreamEvent(_ event: StreamEvent, requestID: String, offsetMS: Double, sampled: Bool = true) throws {
        struct UsagePayload: Encodable {
            var input: Int?
            var output: Int?
            var cached: Int?
            var reasoning: Int?
            var provenance: String
        }
        struct FailurePayload: Encodable {
            var kind: String
            var message: String
        }
        let kind: String
        let payload: String
        switch event {
        case .started: kind = "started"; payload = "{}"
        case .delta(_, let text): kind = "delta"; payload = #"{"text":"\#(JSONCoding.encode(text))"}"#
        case .usage(_, let i, let o, let c, let r, let p):
            kind = "usage"
            payload = JSONCoding.encode(UsagePayload(input: i, output: o, cached: c, reasoning: r, provenance: p.rawValue))
        case .finished(_, let reason, _): kind = "finished"; payload = #"{"reason":"\#(reason.rawValue)"}"#
        case .failed(_, let error, _): kind = "failed"; payload = JSONCoding.encode(FailurePayload(kind: error.kind.rawValue, message: error.message))
        }
        try execute(
            "INSERT INTO stream_events (request_id, backend, event, payload_json, offset_ms, sampled) VALUES (?, ?, ?, ?, ?, ?)",
            bind: [.text(requestID), .text(eventBackend(event).rawValue), .text(kind), .text(payload), .real(offsetMS), .int(sampled ? 1 : 0)]
        )
    }

    private func eventBackend(_ event: StreamEvent) -> BackendID {
        switch event {
        case .started(let backend, _), .delta(let backend, _), .usage(let backend, _, _, _, _, _),
             .finished(let backend, _, _), .failed(let backend, _, _):
            return backend
        }
    }

    public func saveAttachment(_ prepared: AttachmentPipeline.PreparedText, turnID: String, localPath: String?) throws -> String {
        let id = UUID().uuidString
        try execute(
            """
            INSERT INTO attachments (id, turn_id, filename, kind, sha256, byte_size, local_path, page_count, ocr_used, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bind: [
                .text(id), .text(turnID), .text(prepared.filename), .text(prepared.kind.rawValue),
                .text(prepared.sha256), .int(prepared.byteSize), localPath.map { .text($0) } ?? .null,
                prepared.pageCount.map { .int($0) } ?? .null, .int(prepared.usedOCR ? 1 : 0),
                .real(Date().timeIntervalSince1970),
            ]
        )
        for passage in prepared.passages {
            try savePassage(passage, attachmentID: id)
        }
        return id
    }

    public func savePassage(_ passage: ExtractedPassage, attachmentID: String) throws {
        try execute(
            """
            INSERT INTO extracted_passages (id, attachment_id, document_name, page_number, char_offset, char_length, text, injected)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bind: [
                .text(passage.id), .text(attachmentID), .text(passage.documentName),
                passage.pageNumber.map { .int($0) } ?? .null,
                .int(passage.charOffset), .int(passage.charLength), .text(passage.text),
                .int(0),
            ]
        )
        try execute("INSERT INTO passages_fts (text, passage_id) VALUES (?, ?)", bind: [.text(passage.text), .text(passage.id)])
    }

    public func markPassagesInjected(_ ids: [String]) throws {
        for id in ids {
            try execute("UPDATE extracted_passages SET injected = 1 WHERE id = ?", bind: [.text(id)])
        }
    }

    /// FTS5 keyword retrieval: top-N passages matching the query (spec §7).
    public func retrievePassages(matching ftsQuery: String, limit: Int) throws -> [ExtractedPassage] {
        var results: [ExtractedPassage] = []
        try self.query(
            """
            SELECT p.id, p.document_name, p.page_number, p.char_offset, p.char_length, p.text
            FROM passages_fts f
            JOIN extracted_passages p ON p.id = f.passage_id
            WHERE passages_fts MATCH ?
            ORDER BY bm25(passages_fts)
            LIMIT ?
            """,
            bind: [.text(ftsQuery), .int(limit)]
        ) { rowValue in
            results.append(ExtractedPassage(
                id: rowValue.text(0) ?? "",
                documentName: rowValue.text(1) ?? "",
                pageNumber: rowValue.int(2),
                charOffset: rowValue.int(3) ?? 0,
                charLength: rowValue.int(4) ?? 0,
                text: rowValue.text(5) ?? ""
            ))
        }
        return results
    }

    public func saveBenchmarkRun(_ run: BenchmarkRun) throws {
        try execute(
            """
            INSERT OR REPLACE INTO benchmark_runs (id, conversation_id, label, schedule, repetitions, stateless, order_seed, started_at, finished_at, aggregates_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bind: [
                .text(run.id), run.conversationID.map { .text($0) } ?? .null,
                .text(run.label), .text(run.schedule.rawValue), .int(run.repetitions),
                .int(run.stateless ? 1 : 0), run.orderSeed.map { .text($0) } ?? .null,
                .real(run.startedAt.timeIntervalSince1970),
                run.finishedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                run.aggregatesJSON.map { .text($0) } ?? .null,
            ]
        )
        for result in run.results {
            try saveResult(result)
        }
    }

    public func saveIdentity(_ identity: BackendIdentity) throws {
        try execute(
            """
            INSERT OR REPLACE INTO model_configs (id, backend, model_id, display_name, context_size, capabilities_json, captured_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            bind: [
                .text("\(identity.backend.rawValue)-\(identity.modelID)"),
                .text(identity.backend.rawValue), .text(identity.modelID),
                .text(identity.displayName), identity.contextSize.map { .int($0) } ?? .null,
                .text(JSONCoding.encode(identity.capabilities)),
                .real(identity.capturedAt.timeIntervalSince1970),
            ]
        )
    }

    public func deleteAll() throws {
        let tables = ["wire_traces", "metric_samples", "stream_events", "results", "requests", "evaluations",
                      "extracted_passages", "passages_fts", "attachments", "turns", "conversations",
                      "benchmark_runs", "model_configs", "app_environment"]
        for table in tables {
            try execute("DELETE FROM \(table)")
        }
    }
}
