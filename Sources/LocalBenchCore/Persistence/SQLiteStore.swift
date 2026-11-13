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

    /// Current on-disk schema. Bump this and add a new `if version < N` block
    /// in `migrate()` whenever the shape changes. Never edit an already-shipped
    /// block in place: older databases rely on replaying exactly those steps.
    static let schemaVersion = 3

    /// Version 1: conversations, turns, requests, results, evidence, metrics.
    static let ddlV1: [String] = [
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

    /// Version 2: raw, hash-stamped evidence for independent verification.
    static let ddlV2: [String] = [
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
    ]

    /// Version 3: tool-call evidence, richer evaluations, pairwise reviews.
    static let pairwiseEvaluationsDDL = """
        CREATE TABLE IF NOT EXISTS pairwise_evaluations (
            id TEXT PRIMARY KEY,
            request_a_id TEXT NOT NULL REFERENCES requests(id) ON DELETE CASCADE,
            request_b_id TEXT NOT NULL REFERENCES requests(id) ON DELETE CASCADE,
            backend_a TEXT NOT NULL,
            backend_b TEXT NOT NULL,
            winner TEXT NOT NULL,
            blind INTEGER NOT NULL DEFAULT 1,
            notes TEXT NOT NULL DEFAULT '',
            judged_by TEXT NOT NULL DEFAULT 'local reviewer',
            created_at REAL NOT NULL
        );
        """

    private func migrate() throws {
        let current = (try? scalar("PRAGMA user_version").flatMap { Int($0) }) ?? 0
        var version = current

        if version < 1 {
            for statement in Self.ddlV1 {
                try execute(statement)
            }
            version = 1
        }
        if version < 2 {
            for statement in Self.ddlV2 {
                try execute(statement)
            }
            version = 2
        }
        if version < 3 {
            // Version 3 adds columns, so a bare CREATE TABLE IF NOT EXISTS is
            // not enough for databases created by older builds.
            if try !columnExists(table: "results", column: "tool_calls_json") {
                try execute("ALTER TABLE results ADD COLUMN tool_calls_json TEXT")
            }
            if try !columnExists(table: "evaluations", column: "kind") {
                try execute("ALTER TABLE evaluations ADD COLUMN kind TEXT NOT NULL DEFAULT 'rubric'")
            }
            if try !columnExists(table: "evaluations", column: "notes") {
                try execute("ALTER TABLE evaluations ADD COLUMN notes TEXT NOT NULL DEFAULT ''")
            }
            try execute(Self.pairwiseEvaluationsDDL)
            version = 3
        }

        if version != current {
            try execute("PRAGMA user_version=\(version)")
        }
    }

    /// True when `table` already has `column`. Used to make ALTER TABLE
    /// migrations idempotent (a migration may be interrupted after the ALTER
    /// but before `user_version` is committed).
    private func columnExists(table: String, column: String) throws -> Bool {
        var found = false
        try query("PRAGMA table_info(\(table))") { row in
            if row.text(1) == column { found = true }
        }
        return found
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
                attachment_hashes_json, backend_settings_json, created_at, tool_calls_json
            ) VALUES (
                ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
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
                .text(JSONCoding.encode(result.toolCalls)),
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
        case .toolCall(_, let call): kind = "tool_call"; payload = JSONCoding.encode(call)
        }
        try execute(
            "INSERT INTO stream_events (request_id, backend, event, payload_json, offset_ms, sampled) VALUES (?, ?, ?, ?, ?, ?)",
            bind: [.text(requestID), .text(eventBackend(event).rawValue), .text(kind), .text(payload), .real(offsetMS), .int(sampled ? 1 : 0)]
        )
    }

    private func eventBackend(_ event: StreamEvent) -> BackendID {
        switch event {
        case .started(let backend, _), .delta(let backend, _), .usage(let backend, _, _, _, _, _),
             .finished(let backend, _, _), .failed(let backend, _, _), .toolCall(let backend, _):
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

    // MARK: Evaluations (spec §6)

    /// Persisted rubric payload. Version/title live with the scores so an old
    /// review stays interpretable after the rubric evolves.
    private struct StoredRubric: Codable {
        var version: Int?
        var title: String?
        var scores: [RubricScore]
    }

    public func saveEvaluation(_ evaluation: Evaluation) throws {
        let rubric = StoredRubric(
            version: evaluation.rubricVersion,
            title: evaluation.rubricTitle,
            scores: evaluation.scores
        )
        let rubricJSON: String? = (evaluation.rubricVersion == nil && evaluation.scores.isEmpty)
            ? nil
            : JSONCoding.encode(rubric)
        try execute(
            """
            INSERT INTO evaluations (id, request_id, backend, thumbs, rubric_json, judged_by, created_at, kind, notes)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                request_id = excluded.request_id,
                backend = excluded.backend,
                thumbs = excluded.thumbs,
                rubric_json = excluded.rubric_json,
                judged_by = excluded.judged_by,
                kind = excluded.kind,
                notes = excluded.notes
            """,
            bind: [
                .text(evaluation.id), .text(evaluation.requestID), .text(evaluation.backend.rawValue),
                evaluation.thumbs.map { .int($0) } ?? .null,
                rubricJSON.map { .text($0) } ?? .null,
                .text(evaluation.judgedBy), .real(evaluation.createdAt.timeIntervalSince1970),
                .text(evaluation.kind.rawValue), .text(evaluation.notes),
            ]
        )
    }

    public func evaluations(forRequestID requestID: String) throws -> [Evaluation] {
        try evaluations(where: "request_id = ?", bind: [.text(requestID)])
    }

    /// Every review, newest first — used by the Review screen and exports.
    public func evaluations() throws -> [Evaluation] {
        try evaluations(where: nil, bind: [])
    }

    private func evaluations(where clause: String?, bind: [SQLValue]) throws -> [Evaluation] {
        var results: [Evaluation] = []
        let filter = clause.map { "WHERE \($0)" } ?? ""
        try query(
            """
            SELECT id, request_id, backend, thumbs, rubric_json, judged_by, created_at, kind, notes
            FROM evaluations \(filter)
            ORDER BY created_at DESC
            """,
            bind: bind
        ) { row in
            guard let id = row.text(0), let requestID = row.text(1),
                  let backend = BackendID(rawValue: row.text(2) ?? "") else { return }
            var rubric: StoredRubric?
            if let json = row.text(4), let data = json.data(using: .utf8) {
                rubric = try? JSONDecoder().decode(StoredRubric.self, from: data)
            }
            results.append(Evaluation(
                id: id,
                requestID: requestID,
                backend: backend,
                kind: EvaluationKind(rawValue: row.text(7) ?? "") ?? .rubric,
                thumbs: row.int(3),
                rubricVersion: rubric?.version,
                rubricTitle: rubric?.title,
                scores: rubric?.scores ?? [],
                notes: row.text(8) ?? "",
                judgedBy: row.text(5) ?? "local reviewer",
                createdAt: Date(timeIntervalSince1970: row.double(6) ?? 0)
            ))
        }
        return results
    }

    public func deleteEvaluation(id: String) throws {
        try execute("DELETE FROM evaluations WHERE id = ?", bind: [.text(id)])
    }

    public func savePairwiseEvaluation(_ evaluation: PairwiseEvaluation) throws {
        try execute(
            """
            INSERT INTO pairwise_evaluations
                (id, request_a_id, request_b_id, backend_a, backend_b, winner, blind, notes, judged_by, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                request_a_id = excluded.request_a_id,
                request_b_id = excluded.request_b_id,
                backend_a = excluded.backend_a,
                backend_b = excluded.backend_b,
                winner = excluded.winner,
                blind = excluded.blind,
                notes = excluded.notes,
                judged_by = excluded.judged_by
            """,
            bind: [
                .text(evaluation.id), .text(evaluation.requestAID), .text(evaluation.requestBID),
                .text(evaluation.backendA.rawValue), .text(evaluation.backendB.rawValue),
                .text(evaluation.winner.rawValue), .int(evaluation.blind ? 1 : 0),
                .text(evaluation.notes), .text(evaluation.judgedBy),
                .real(evaluation.createdAt.timeIntervalSince1970),
            ]
        )
    }

    public func pairwiseEvaluations() throws -> [PairwiseEvaluation] {
        var results: [PairwiseEvaluation] = []
        try query(
            """
            SELECT id, request_a_id, request_b_id, backend_a, backend_b, winner, blind, notes, judged_by, created_at
            FROM pairwise_evaluations
            ORDER BY created_at DESC
            """
        ) { row in
            guard let id = row.text(0), let a = row.text(1), let b = row.text(2),
                  let backendA = BackendID(rawValue: row.text(3) ?? ""),
                  let backendB = BackendID(rawValue: row.text(4) ?? ""),
                  let winner = PairwiseEvaluation.Winner(rawValue: row.text(5) ?? "") else { return }
            results.append(PairwiseEvaluation(
                id: id, requestAID: a, requestBID: b,
                backendA: backendA, backendB: backendB, winner: winner,
                blind: (row.int(6) ?? 1) == 1,
                notes: row.text(7) ?? "", judgedBy: row.text(8) ?? "local reviewer",
                createdAt: Date(timeIntervalSince1970: row.double(9) ?? 0)
            ))
        }
        return results
    }

    public func deletePairwiseEvaluation(id: String) throws {
        try execute("DELETE FROM pairwise_evaluations WHERE id = ?", bind: [.text(id)])
    }

    // MARK: Conversation restore (spec §8)

    /// Rebuild saved conversations (and their turns/results) from SQLite so
    /// the chat UI survives app restarts.
    public func savedConversations() throws -> [Conversation] {
        var conversations: [Conversation] = []
        try query("SELECT id, title, created_at FROM conversations ORDER BY created_at ASC") { row in
            guard let id = row.text(0) else { return }
            conversations.append(Conversation(
                id: id,
                title: row.text(1) ?? "Conversation",
                createdAt: Date(timeIntervalSince1970: row.double(2) ?? 0)
            ))
        }
        for index in conversations.indices {
            conversations[index].turns = try savedTurns(conversationID: conversations[index].id)
        }
        return conversations
    }

    public func savedTurns(conversationID: String) throws -> [Turn] {
        var turns: [Turn] = []
        try query(
            """
            SELECT id, turn_index, canonical_user_text, canonical_prompt_sha256, schedule, mode, created_at
            FROM turns WHERE conversation_id = ? ORDER BY turn_index ASC, created_at ASC
            """,
            bind: [.text(conversationID)]
        ) { row in
            guard let id = row.text(0) else { return }
            turns.append(Turn(
                id: id,
                turnIndex: row.int(1) ?? 0,
                canonicalUserText: row.text(2) ?? "",
                promptHash: row.text(3) ?? "",
                records: [:],
                schedule: RunSchedule(rawValue: row.text(4) ?? "") ?? .sequential,
                mode: RunMode(rawValue: row.text(5) ?? "") ?? .conversation,
                createdAt: Date(timeIntervalSince1970: row.double(6) ?? 0)
            ))
        }
        for index in turns.indices {
            turns[index].records = try savedRecords(turnID: turns[index].id, conversationID: conversationID)
        }
        return turns
    }

    private func savedRecords(turnID: String, conversationID: String) throws -> [BackendID: TurnRecord] {
        var records: [BackendID: TurnRecord] = [:]
        try query(
            """
            SELECT res.request_id, res.backend, res.model_id, res.os_version, res.os_build,
                   res.ttft_ms, res.wall_ms, res.output_tokens_per_second, res.prefill_tokens_per_second,
                   res.input_tokens, res.output_tokens, res.cached_tokens, res.reasoning_tokens, res.token_provenance,
                   res.peak_footprint_mb, res.system_peak_pressure, res.memory_scope, res.raw_text,
                   res.error_kind, res.error_message, res.finish_reason, res.warmth, res.repetition_index,
                   res.schedule, res.mode, res.options_json, res.prompt_hash, res.attachment_hashes_json,
                   res.backend_settings_json, res.tool_calls_json, res.created_at
            FROM results res
            JOIN requests req ON req.id = res.request_id
            WHERE req.turn_id = ?
            ORDER BY res.backend
            """,
            bind: [.text(turnID)]
        ) { row in
            guard let result = Self.resultEnvelope(from: row, conversationID: conversationID) else { return }
            records[result.backend] = TurnRecord(
                backend: result.backend,
                streamedText: result.rawText,
                result: result
            )
        }
        return records
    }

    /// Where a request came from, for Trace → Conversation reverse navigation.
    public struct RequestContext: Sendable, Hashable {
        public var requestID: String
        public var conversationID: String
        public var turnID: String
        public var turnIndex: Int
        public var userText: String
        public var backend: BackendID
        public var modelID: String
        public var rawText: String
        public var createdAt: Date

        public init(requestID: String, conversationID: String, turnID: String, turnIndex: Int,
                    userText: String, backend: BackendID, modelID: String, rawText: String, createdAt: Date) {
            self.requestID = requestID
            self.conversationID = conversationID
            self.turnID = turnID
            self.turnIndex = turnIndex
            self.userText = userText
            self.backend = backend
            self.modelID = modelID
            self.rawText = rawText
            self.createdAt = createdAt
        }
    }

    public func requestContext(requestID: String) throws -> RequestContext? {
        var context: RequestContext?
        try query(
            """
            SELECT r.id, t.conversation_id, t.id, t.turn_index, t.canonical_user_text,
                   r.backend, COALESCE(res.model_id, ''), COALESCE(res.raw_text, ''), r.created_at
            FROM requests r
            JOIN turns t ON t.id = r.turn_id
            LEFT JOIN results res ON res.request_id = r.id
            WHERE r.id = ?
            """,
            bind: [.text(requestID)]
        ) { row in
            guard let id = row.text(0), let conversationID = row.text(1), let turnID = row.text(2),
                  let backend = BackendID(rawValue: row.text(5) ?? "") else { return }
            context = RequestContext(
                requestID: id, conversationID: conversationID, turnID: turnID,
                turnIndex: row.int(3) ?? 0, userText: row.text(4) ?? "",
                backend: backend, modelID: row.text(6) ?? "", rawText: row.text(7) ?? "",
                createdAt: Date(timeIntervalSince1970: row.double(8) ?? 0)
            )
        }
        return context
    }

    public func deleteAll() throws {
        let tables = ["wire_traces", "metric_samples", "stream_events", "results", "requests",
                      "evaluations", "pairwise_evaluations",
                      "extracted_passages", "passages_fts", "attachments", "turns", "conversations",
                      "benchmark_runs", "model_configs", "app_environment"]
        for table in tables {
            try execute("DELETE FROM \(table)")
        }
    }
}
