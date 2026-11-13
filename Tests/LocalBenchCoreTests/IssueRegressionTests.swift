import Testing
import Foundation
@testable import LocalBenchCore

/// Regression coverage for the open-issue audit: every test here corresponds
/// to a behavior that was previously missing, wrong, or silently degraded.
@Suite("Issue regressions — streaming & metrics")
struct StreamingAndMetricsRegressionTests {
    @Test func feedLineDispatchesEachSSEEventWithoutTrailingNewline() {
        // The LM Studio stream reader hands over `AsyncBytes.lines`, which has
        // already stripped the newline. Feeding those lines to `feed` (instead
        // of `feedLine`) buffers every chunk until finish() and then decodes
        // the concatenated JSON as one broken payload.
        var parser = SSEParser()
        var events: [SSEParser.Event] = []
        events += parser.feedLine(#"data: {"choices":[{"delta":{"content":"hi"}}]}"#)
        #expect(events.isEmpty)
        events += parser.feedLine("")
        #expect(events == [.data(#"{"choices":[{"delta":{"content":"hi"}}]}"#)])
        events += parser.feedLine("data: [DONE]")
        events += parser.feedLine("")
        #expect(events.last == .done)
    }

    @Test func lineFeederKeepsUnicodeSeparatorsInsideJSONStrings() {
        // U+2028/U+2029 are legal unescaped JSON string characters. They are
        // not SSE line terminators; a client must not split a payload on them.
        let payload = "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"one\u{2028}two\u{2029}three\"}}]}"
        var parser = SSEParser()
        var events: [SSEParser.Event] = []
        events += parser.feedLine(payload)
        events += parser.feedLine("")
        #expect(events == [.data(String(payload.dropFirst("data: ".count)))])
        if case .data(let decoded) = events[0] {
            #expect(decoded.contains("\u{2028}"))
            #expect(decoded.contains("\u{2029}"))
        }
    }

    @Test func captureAwareStreamDispatchesThroughExistential() async throws {
        final class ProbeBackend: ChatBackend, @unchecked Sendable {
            var id: BackendID { .lmStudio }
            func availabilityReport() async -> AvailabilityReport {
                AvailabilityReport(backend: .lmStudio, isAvailable: false, reason: "probe", actionableAdvice: "")
            }
            func stream(_ envelope: RequestEnvelope) -> AsyncThrowingStream<StreamEvent, Error> {
                AsyncThrowingStream { $0.finish() }
            }
            func stream(_ envelope: RequestEnvelope, capture: StreamCapture?) -> AsyncThrowingStream<StreamEvent, Error> {
                capture?.append(kind: .meta, data: "capture-aware dispatched")
                return AsyncThrowingStream { $0.finish() }
            }
        }
        let capture = StreamCapture()
        let backend: any ChatBackend = ProbeBackend()
        for try await _ in backend.stream(RequestEnvelope(conversationID: "c", turnIndex: 0, canonicalUserText: "q"), capture: capture) {}
        #expect(capture.snapshot().first?.data == "capture-aware dispatched")
    }

    @Test func subFiftyMillisecondDecodeWindowIsUnavailable() {
        let dispatch: UInt64 = 1_000_000_000
        // 3 tokens in 100 µs would otherwise read as ~30,000 tok/s.
        #expect(Metrics.outputTokensPerSecond(outputTokens: 3, firstContentNS: dispatch, endNS: dispatch + 100_000) == nil)
        // At the documented 50 ms floor the rate is computable and sane.
        let tps = Metrics.outputTokensPerSecond(outputTokens: 3, firstContentNS: dispatch, endNS: dispatch + 50_000_000)
        #expect(tps != nil)
        #expect(abs((tps ?? 0) - 60) < 0.001)
    }

    @Test func kernelPressureValuesMapToDocumentedScale() {
        #expect(MemorySampler.pressureLevel(fromKernelValue: 1) == 0)
        #expect(MemorySampler.pressureLevel(fromKernelValue: 2) == 1)
        #expect(MemorySampler.pressureLevel(fromKernelValue: 4) == 2)
        #expect(MemorySampler.pressureLevel(fromKernelValue: 0) == nil)
        #expect(MemorySampler.pressureLevel(fromKernelValue: 3) == nil)
    }

    @Test func redirectGuardOnlyAllowsLoopbackTargets() {
        #expect(LoopbackRedirectGuard.isAllowedRedirect(URLRequest(url: URL(string: "http://127.0.0.1:1234/v1/chat/completions")!)))
        #expect(LoopbackRedirectGuard.isAllowedRedirect(URLRequest(url: URL(string: "http://localhost:1234/v1/models")!)))
        #expect(!LoopbackRedirectGuard.isAllowedRedirect(URLRequest(url: URL(string: "https://api.example.com/steal")!)))
        #expect(!LoopbackRedirectGuard.isAllowedRedirect(URLRequest(url: URL(string: "http://192.168.1.5:1234")!)))
    }
}

@Suite("Issue regressions — verification")
struct VerificationRegressionTests {
    @Test func reasoningOnlyResponseVerifiesWithoutVisibleContent() {
        // A reasoning model can spend the whole token budget on
        // `reasoning_content` and return finish_reason=length with empty
        // visible text. That is consistent evidence, not a verifier failure.
        let chunks = [
            #"data: {"choices":[{"index":0,"delta":{"reasoning_content":"thinking"}}]}"#,
            #"data: {"choices":[{"index":0,"delta":{},"finish_reason":"length"}]}"#,
            #"data: {"choices":[],"usage":{"prompt_tokens":29,"completion_tokens":95,"total_tokens":124,"completion_tokens_details":{"reasoning_tokens":95}}}"#,
            "data: [DONE]",
        ]
        let offsets = [10.0, 900.0, 1000.0, 1000.0]
        let records = chunks.enumerated().map { index, line in
            TraceRecord(
                seq: index, kind: .sseLine, offsetMS: offsets[index],
                byteCount: line.utf8.count, sha256: Sha256.hex(line), data: line
            )
        }
        let expected = TraceVerifier.Expected(
            modelID: "reasoning-model",
            ttftMS: nil,
            wallMS: 1000,
            outputTokensPerSecond: nil,
            inputTokens: 29,
            outputTokens: 95,
            tokenProvenance: "server",
            errorKind: nil,
            rawText: ""
        )
        let report = TraceVerifier.verify(records: records, expected: expected)
        #expect(report.passed)
        #expect(report.recomputedTTFTMS == nil)
        #expect(report.recomputedOutputTokens == 95)
    }

    @Test func fabricatedTextWithNoContentEvidenceStillFails() {
        let line = #"data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#
        let records = [TraceRecord(
            seq: 0, kind: .sseLine, offsetMS: 100,
            byteCount: line.utf8.count, sha256: Sha256.hex(line), data: line
        )]
        let expected = TraceVerifier.Expected(
            modelID: "m", ttftMS: 80, wallMS: 100, outputTokensPerSecond: nil,
            inputTokens: nil, outputTokens: nil, errorKind: nil, rawText: "invented answer"
        )
        let report = TraceVerifier.verify(records: records, expected: expected)
        #expect(!report.passed)
        #expect(report.findings.contains { $0.contains("no content-bearing line") })
    }
}

@Suite("Issue regressions — tool calling")
struct ToolCallingRegressionTests {
    @Test func toolDeclarationsChangePromptHashAndRoundTrip() throws {
        let plain = RequestEnvelope(conversationID: "c", turnIndex: 0, canonicalUserText: "q")
        let tool = ToolDefinition(
            name: "weather",
            description: "Get the weather",
            parametersJSONSchema: #"{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}"#
        )
        let withTool = RequestEnvelope(conversationID: "c", turnIndex: 0, canonicalUserText: "q", tools: [tool])
        #expect(plain.promptHash != withTool.promptHash)
        #expect(tool.parametersObject?["type"] as? String == "object")
    }

    @Test func lmStudioWireRequestSerializesToolSchema() throws {
        let tool = ToolDefinition(
            name: "lookup",
            description: "Look something up",
            parametersJSONSchema: #"{"type":"object","properties":{"id":{"type":"integer"}}}"#
        )
        let schema = tool.parametersObject ?? [:]
        let request = LMStudioWire.ChatRequest(
            model: "m",
            messages: [.init(role: "user", text: "hi")],
            stream: true,
            streamOptions: .init(includeUsage: true),
            temperature: nil,
            maxTokens: nil,
            topP: nil,
            seed: nil,
            responseFormat: nil
        )
        var withTools = request
        withTools.tools = [.init(function: .init(
            name: tool.name,
            description: tool.description,
            parameters: schema.mapValues { AnyCodable(anyValue: $0) }
        ))]
        let data = try JSONEncoder().encode(withTools)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let tools = object?["tools"] as? [[String: Any]]
        #expect(tools?.first?["type"] as? String == "function")
        let function = tools?.first?["function"] as? [String: Any]
        #expect(function?["name"] as? String == "lookup")
        #expect((function?["parameters"] as? [String: Any])?["type"] as? String == "object")
    }

    @Test func toolCallDeltaStreamIsParsedNotDropped() throws {
        let json = #"""
        {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"lookup","arguments":"{\"id\":"}}]},"finish_reason":null}]}
        """#
        let chunk = try JSONDecoder().decode(LMStudioWire.StreamChunk.self, from: Data(json.utf8))
        let delta = chunk.choices?.first?.delta?.toolCalls?.first
        #expect(delta?.id == "call_1")
        #expect(delta?.function?.name == "lookup")
        #expect(delta?.function?.arguments == #"{"id":"#)
    }

    @Test func toolCallsPersistAndReloadWithResult() throws {
        let store = try SQLiteStore.inMemory()
        let conversation = Conversation(title: "tools")
        try store.saveConversation(conversation)
        let envelope = RequestEnvelope(conversationID: conversation.id, turnIndex: 0, canonicalUserText: "call it")
        let turn = Turn(turnIndex: 0, canonicalUserText: "call it", promptHash: envelope.promptHash)
        try store.saveTurn(turn, conversationID: conversation.id)
        try store.saveRequest(envelope: envelope, turnID: turn.id, backend: .lmStudio)
        let call = ToolCall(id: "call_1", name: "lookup", argumentsJSON: #"{"id":7}"#)
        let result = makeResult(envelope: envelope, backend: .lmStudio, text: "", toolCalls: [call])
        try store.saveResult(result)

        let restored = try store.savedConversations()
        let record = restored.first?.turns.first?.records[.lmStudio]
        #expect(record?.result?.toolCalls == [call])
    }
}

@Suite("Issue regressions — schema evolution")
struct SchemaEvolutionRegressionTests {
    @Test func freshDatabaseHasVersionThreeShape() throws {
        let store = try SQLiteStore.inMemory()
        #expect(try store.scalar("PRAGMA user_version") == "3")
        #expect(try columns(of: "results", in: store).contains("tool_calls_json"))
        #expect(try columns(of: "evaluations", in: store).contains("kind"))
        #expect(try columns(of: "evaluations", in: store).contains("notes"))
        var pairwiseExists = false
        try store.query("SELECT name FROM sqlite_master WHERE type='table' AND name='pairwise_evaluations'") { row in
            pairwiseExists = row.text(0) == "pairwise_evaluations"
        }
        #expect(pairwiseExists)
    }

    @Test func versionTwoDatabaseGainsAdditiveColumnsAndKeepsRows() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("localbench-migration-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        // Create a current DB, then strip the v3 additions to emulate a v2 file.
        do {
            let store = try SQLiteStore(path: path)
            let conversation = Conversation(title: "legacy")
            try store.saveConversation(conversation)
            let envelope = RequestEnvelope(conversationID: conversation.id, turnIndex: 0, canonicalUserText: "old")
            let turn = Turn(turnIndex: 0, canonicalUserText: "old")
            try store.saveTurn(turn, conversationID: conversation.id)
            try store.saveRequest(envelope: envelope, turnID: turn.id, backend: .apple)
            try store.saveResult(makeResult(envelope: envelope, backend: .apple, text: "old answer"))
            try store.execute("DROP TABLE pairwise_evaluations")
            try store.execute("ALTER TABLE results DROP COLUMN tool_calls_json")
            try store.execute("ALTER TABLE evaluations DROP COLUMN kind")
            try store.execute("ALTER TABLE evaluations DROP COLUMN notes")
            try store.execute("PRAGMA user_version=2")
        }

        let upgraded = try SQLiteStore(path: path)
        #expect(try upgraded.scalar("PRAGMA user_version") == "3")
        #expect(try columns(of: "results", in: upgraded).contains("tool_calls_json"))
        #expect(try columns(of: "evaluations", in: upgraded).contains("kind"))
        #expect(try columns(of: "evaluations", in: upgraded).contains("notes"))
        var resultCount: Int?
        try upgraded.query("SELECT COUNT(*) FROM results") { row in resultCount = row.int(0) }
        #expect(resultCount == 1)
    }

    private func columns(of table: String, in store: SQLiteStore) throws -> [String] {
        var names: [String] = []
        try store.query("PRAGMA table_info(\(table))") { row in
            if let name = row.text(1) { names.append(name) }
        }
        return names
    }
}

@Suite("Issue regressions — evaluations and restore")
struct EvaluationAndRestoreRegressionTests {
    @Test func evaluationRubricAndPairwiseRoundTrip() throws {
        let store = try SQLiteStore.inMemory()
        let (turn, appleEnvelope, appleResult) = try seed(store: store, conversationID: "review", turnIndex: 0)
        let lmEnvelope = RequestEnvelope(conversationID: "review", turnIndex: 0, canonicalUserText: "q")
        let lmResult = makeResult(envelope: lmEnvelope, backend: .lmStudio, text: "lm answer")
        try store.saveRequest(envelope: lmEnvelope, turnID: turn.id, backend: .lmStudio)
        try store.saveResult(lmResult)

        let scores = EvaluationRubric.v1.criteria.enumerated().map { index, criterion in
            RubricScore(criterionID: criterion.id, score: min(index + 1, criterion.maximumScore))
        }
        let evaluation = Evaluation(
            requestID: appleEnvelope.requestID,
            backend: .apple,
            kind: .rubric,
            thumbs: 1,
            rubricVersion: EvaluationRubric.v1.version,
            rubricTitle: EvaluationRubric.v1.title,
            scores: scores,
            notes: "grounded and clear",
            judgedBy: "reviewer-a"
        )
        try store.saveEvaluation(evaluation)
        let loaded = try store.evaluations(forRequestID: appleEnvelope.requestID)
        #expect(loaded.count == 1)
        #expect(loaded.first?.scores == scores)
        #expect(loaded.first?.notes == "grounded and clear")
        #expect(loaded.first?.rubricVersion == EvaluationRubric.v1.version)
        #expect(loaded.first?.totalScore == scores.reduce(0) { $0 + $1.score })

        let pairwise = PairwiseEvaluation(
            requestAID: appleEnvelope.requestID,
            requestBID: lmEnvelope.requestID,
            backendA: .apple,
            backendB: .lmStudio,
            winner: .b,
            blind: true,
            notes: "B is more specific"
        )
        try store.savePairwiseEvaluation(pairwise)
        let decisions = try store.pairwiseEvaluations()
        #expect(decisions.count == 1)
        #expect(decisions.first?.winner == .b)
        #expect(decisions.first?.blind == true)
        #expect(decisions.first?.winningRequestID == lmEnvelope.requestID)

        try store.deleteEvaluation(id: evaluation.id)
        #expect(try store.evaluations(forRequestID: appleEnvelope.requestID).isEmpty)
        // The response itself is untouched by deleting a review.
        #expect(try store.savedConversations().first?.turns.first?.records[.apple]?.result?.rawText == appleResult.rawText)
    }

    @Test func savedConversationsRestoreTurnsAndRecords() throws {
        let store = try SQLiteStore.inMemory()
        let conversation = Conversation(title: "persisted")
        try store.saveConversation(conversation)
        let first = RequestEnvelope(conversationID: conversation.id, turnIndex: 0, canonicalUserText: "first")
        let firstTurn = Turn(turnIndex: 0, canonicalUserText: "first", promptHash: first.promptHash)
        try store.saveTurn(firstTurn, conversationID: conversation.id)
        try store.saveRequest(envelope: first, turnID: firstTurn.id, backend: .apple)
        try store.saveResult(makeResult(envelope: first, backend: .apple, text: "first answer"))

        let second = RequestEnvelope(conversationID: conversation.id, turnIndex: 1, canonicalUserText: "second")
        let secondTurn = Turn(turnIndex: 1, canonicalUserText: "second", promptHash: second.promptHash)
        try store.saveTurn(secondTurn, conversationID: conversation.id)
        try store.saveRequest(envelope: second, turnID: secondTurn.id, backend: .lmStudio)
        try store.saveResult(makeResult(envelope: second, backend: .lmStudio, text: "second answer"))

        let restored = try store.savedConversations()
        #expect(restored.count == 1)
        #expect(restored.first?.turns.count == 2)
        #expect(restored.first?.turns[0].canonicalUserText == "first")
        #expect(restored.first?.turns[0].records[.apple]?.streamedText == "first answer")
        #expect(restored.first?.turns[1].records[.lmStudio]?.streamedText == "second answer")

        let context = try store.requestContext(requestID: second.requestID)
        #expect(context?.conversationID == conversation.id)
        #expect(context?.turnID == secondTurn.id)
        #expect(context?.backend == .lmStudio)
        #expect(context?.userText == "second")
    }

    @Test func evaluationBundleIsSelfContainedJSON() throws {
        let store = try SQLiteStore.inMemory()
        let (_, envelope, result) = try seed(store: store, conversationID: "export", turnIndex: 0)
        let evaluation = Evaluation(
            requestID: envelope.requestID, backend: .apple, kind: .thumbs, thumbs: 1,
            notes: "fine", judgedBy: "reviewer"
        )
        try store.saveEvaluation(evaluation)
        let responses = try store.reviewableResponses()
        #expect(responses.first?.rawText == result.rawText)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("localbench-eval-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try ExportService.writeEvaluationBundle(
            evaluations: try store.evaluations(),
            pairwise: try store.pairwiseEvaluations(),
            responses: responses,
            to: directory
        )
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect((object?["evaluations"] as? [[String: Any]])?.count == 1)
        let exportedResponses = object?["responses"] as? [[String: Any]]
        #expect(exportedResponses?.first?["rawText"] as? String == result.rawText)
    }

    private func seed(store: SQLiteStore, conversationID: String, turnIndex: Int) throws -> (Turn, RequestEnvelope, ResultEnvelope) {
        let conversation = Conversation(id: conversationID, title: "seed")
        try store.saveConversation(conversation)
        let envelope = RequestEnvelope(conversationID: conversationID, turnIndex: turnIndex, canonicalUserText: "q")
        let turn = Turn(turnIndex: turnIndex, canonicalUserText: "q", promptHash: envelope.promptHash)
        try store.saveTurn(turn, conversationID: conversationID)
        try store.saveRequest(envelope: envelope, turnID: turn.id, backend: .apple)
        let result = makeResult(envelope: envelope, backend: .apple, text: "apple answer")
        try store.saveResult(result)
        return (turn, envelope, result)
    }
}

@Suite("Issue regressions — Apple transcript")
struct AppleTranscriptRegressionTests {
    @Test func transcriptInterleavesPriorUserAndAssistantTurns() {
        let envelope = RequestEnvelope(
            conversationID: "c",
            turnIndex: 2,
            canonicalUserText: "third question",
            priorUserMessages: ["first question", "second question"],
            assistantHistory: [
                .init(text: "first answer"),
                .init(text: "second answer"),
            ]
        )
        let transcript = AppleBackend.transcript(for: envelope, instructions: "system")
        // instructions + user + assistant + user + assistant
        #expect(transcript.count == 5)
    }

    @Test func statelessTranscriptDropsAssistantHistory() {
        let envelope = RequestEnvelope(
            conversationID: "c",
            turnIndex: 1,
            canonicalUserText: "q",
            priorUserMessages: ["prior"],
            assistantHistory: [.init(text: "should not appear")],
            mode: .stateless
        )
        let transcript = AppleBackend.transcript(for: envelope, instructions: "system")
        // instructions + prior user only; assistant history is suppressed.
        #expect(transcript.count == 2)
    }
}

private func makeResult(envelope: RequestEnvelope,
                        backend: BackendID,
                        text: String,
                        toolCalls: [ToolCall] = []) -> ResultEnvelope {
    ResultEnvelope(
        requestID: envelope.requestID,
        conversationID: envelope.conversationID,
        turnIndex: envelope.turnIndex,
        backend: backend,
        modelID: backend == .apple ? "AFM" : "lm-model",
        osVersion: "27.0.1",
        osBuild: "26A434",
        dispatchMonotonicNS: 1,
        firstContentMonotonicNS: 60_000_000,
        endMonotonicNS: 200_000_000,
        ttftMS: 59,
        wallMS: 199,
        outputTokensPerSecond: 20,
        inputTokens: 5,
        outputTokens: 4,
        tokenProvenance: backend == .apple ? .native : .server,
        rawText: text,
        toolCalls: toolCalls,
        finishReason: .stop,
        warmth: .warm,
        repetitionIndex: envelope.turnIndex,
        schedule: envelope.schedule,
        mode: envelope.mode,
        options: envelope.options,
        promptHash: envelope.promptHash,
        attachmentSHA256s: envelope.attachmentSHA256s
    )
}
