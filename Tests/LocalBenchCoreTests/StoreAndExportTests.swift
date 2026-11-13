import Testing
import Foundation
@testable import LocalBenchCore

@Suite("SQLite store + retrieval")
struct SQLiteStoreTests {
    func makeStore() throws -> SQLiteStore {
        try SQLiteStore.inMemory()
    }

    @Test func schemaMigrationsApplyAndVersionSet() throws {
        let store = try makeStore()
        let version = try store.scalar("PRAGMA user_version")
        #expect(version == String(SQLiteStore.schemaVersion)) // v2 = wire_traces evidence table
    }

    @Test func conversationTurnResultRoundTrip() throws {
        let store = try makeStore()
        let conversation = Conversation(title: "test")
        try store.saveConversation(conversation)
        let envelope = RequestEnvelope(conversationID: conversation.id, turnIndex: 0, canonicalUserText: "hello", schedule: .sequential)
        let turn = Turn(turnIndex: 0, canonicalUserText: "hello", promptHash: envelope.promptHash, schedule: .sequential, mode: .conversation)
        try store.saveTurn(turn, conversationID: conversation.id)
        try store.saveRequest(envelope: envelope, turnID: turn.id, backend: .apple)
        let result = ResultEnvelope(
            requestID: envelope.requestID, conversationID: conversation.id, turnIndex: 0,
            backend: .apple, modelID: "AFM 3 Core Advanced", osVersion: "27.0.1", osBuild: "26A434",
            dispatchMonotonicNS: 0, firstContentMonotonicNS: 100_000_000, endMonotonicNS: 500_000_000,
            ttftMS: 100, wallMS: 500, outputTokensPerSecond: 12.5,
            inputTokens: 7, outputTokens: 5, tokenProvenance: .native,
            peakProcessFootprintMB: 9.3, memoryScopeNote: "process self",
            rawText: "hi", finishReason: .stop, warmth: .warm, repetitionIndex: 0,
            schedule: .sequential, mode: .conversation, promptHash: envelope.promptHash
        )
        try store.saveResult(result)
        try store.saveBenchmarkRun(BenchmarkRun(label: "run", schedule: .sequential, repetitions: 1, stateless: false, results: [result]))

        var count = 0
        try store.query("SELECT COUNT(*) FROM results") { _ in count += 1 }
        // COUNT(*) always returns a row
        var value: Int?
        try store.query("SELECT COUNT(*) FROM results") { row in value = row.int(0) }
        #expect(value == 1)
        #expect(count == 1)
    }

    @Test func passageInsertAndFTSRetrieval() throws {
        let store = try makeStore()
        let prepared = AttachmentPipeline.PreparedText(
            kind: .pdf, filename: "report.pdf", sha256: "abc", byteSize: 100,
            passages: [
                ExtractedPassage(documentName: "report.pdf", pageNumber: 1, charOffset: 0, charLength: 20, text: "Quarterly revenue increased sharply"),
                ExtractedPassage(documentName: "report.pdf", pageNumber: 2, charOffset: 40, charLength: 20, text: "The weather in Quito is mild"),
            ],
            pageCount: 2, usedOCR: false
        )
        // Attachments need a turn row (FK).
        let turn = Turn(turnIndex: 0, canonicalUserText: "q")
        try store.saveTurn(turn, conversationID: "cftstest")
        let attachmentID = try store.saveAttachment(prepared, turnID: turn.id, localPath: nil)
        #expect(!attachmentID.isEmpty)

        let hits = try store.retrievePassages(matching: "revenue", limit: 5)
        #expect(hits.count == 1)
        #expect(hits.first?.pageNumber == 1)
        #expect(hits.first?.documentName == "report.pdf")

        let miss = try store.retrievePassages(matching: "quantumflubber", limit: 5)
        #expect(miss.isEmpty)
    }

    @Test func deleteAllClearsEverything() throws {
        let store = try makeStore()
        let turn = Turn(turnIndex: 0, canonicalUserText: "q")
        try store.saveTurn(turn, conversationID: "cdel")
        try store.deleteAll()
        var conversations = 0
        try store.query("SELECT COUNT(*) FROM conversations") { row in conversations = row.int(0) ?? 0 }
        #expect(conversations == 0)
    }

    @Test func metricSamplesPersistWithScope() throws {
        let store = try makeStore()
        let envelope = RequestEnvelope(conversationID: "c", turnIndex: 0, canonicalUserText: "q")
        let turn = Turn(turnIndex: 0, canonicalUserText: "q")
        try store.saveTurn(turn, conversationID: "csample")
        try store.saveRequest(envelope: envelope, turnID: turn.id, backend: .apple)
        let samples = [
            MemorySample(offsetMS: 0, processFootprintMB: 4.2, systemFreePagesMB: 1024, systemPressureLevel: 0, scopeNote: "process self"),
            MemorySample(offsetMS: 250, processFootprintMB: 9.1, systemFreePagesMB: 900, systemPressureLevel: 1, scopeNote: "process self"),
        ]
        try store.saveMetricSamples(samples, requestID: envelope.requestID)
        var peak: Double?
        try store.query("SELECT MAX(footprint_mb) FROM metric_samples") { row in peak = row.double(0) }
        #expect(abs(peak! - 9.1) < 0.001)
    }
}

@Suite("Export artifacts")
struct ExportTests {
    @Test func csvIncludesProvenanceColumnsAndNeverFakeExactness() throws {
        let result = ResultEnvelope(
            requestID: "r", conversationID: "c", turnIndex: 0, backend: .apple, modelID: "AFM 3",
            osVersion: "27.0.1", osBuild: "26A434",
            dispatchMonotonicNS: 1, firstContentMonotonicNS: 2, endMonotonicNS: 3,
            ttftMS: 1.0, wallMS: 2.0, outputTokensPerSecond: 5,
            inputTokens: 7, outputTokens: nil, tokenProvenance: .native,
            finishReason: .stop, warmth: .cold, promptHash: "deadbeef"
        )
        let run = BenchmarkRun(label: "t", schedule: .sequential, repetitions: 1, stateless: false, results: [result])
        let csv = ExportService.csv(for: run)
        #expect(csv.contains("token_provenance"))
        #expect(csv.contains("prompt_hash"))
        #expect(csv.contains("deadbeef"))
        #expect(csv.contains("native"))
        #expect(csv.contains("n/a")) // missing output tokens shown as n/a, not zero
    }

    @Test func csvEscapesCommasAndQuotes() {
        #expect(ExportService.csvEscape("plain") == "plain")
        #expect(ExportService.csvEscape("a,b") == "\"a,b\"")
        #expect(ExportService.csvEscape("say \"hi\"") == "\"say \"\"hi\"\"\"")
    }

    @Test func jsonExportContainsEnvironmentAndNotes() throws {
        let run = BenchmarkRun(label: "t", schedule: .sequential, repetitions: 1, stateless: false, results: [])
        let data = try ExportService.json(for: run)
        let text = String(data: data, encoding: .utf8) ?? ""
        #expect(text.contains("\"environment\""))
        #expect(text.contains("prefill tokens per second omitted"))
        #expect(text.contains("on-device only"))
    }
}
