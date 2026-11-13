import Foundation
import LocalBenchCore

/// localbench CLI — capability report + headless benchmarks with exports.
@main
struct LocalBenchCLI {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else {
            printUsage()
            return
        }
        switch command {
        case "capabilities": await capabilities()
        case "run": await runBenchmark(Array(arguments.dropFirst()))
        case "chat": await chat(Array(arguments.dropFirst()))
        case "verify": await verify(Array(arguments.dropFirst()))
        case "help", "--help", "-h": printUsage()
        default:
            print("Unknown command: \(command)")
            printUsage()
            exit(2)
        }
    }

    static func printUsage() {
        print("""
        localbench — LocalBench CLI (local inference only)

        Commands:
          capabilities
              Print runtime capability matrix for both backends.
          run --prompt "..." [--backends apple,lmstudio] [--schedule sequential|parallel]
              [--reps N] [--stateless] [--no-prewarm] [--temperature 0.7] [--max-tokens 512]
              [--seed 42] [--system "..."] [--attach file.pdf ...]
              [--lm-model ID] [--lm-url http://127.0.0.1:1234]
              [--db PATH] [--export-dir PATH] [--ocr]
              Runs the canonical prompt against the selected backends and
              persists measurements, full trace evidence, and CSV/JSON exports.
          chat --prompt "..." [--prompt "..." ...] [--backends apple,lmstudio]
              [--stateless] [--lm-model ID] [--max-tokens 512] [--db PATH]
              Runs consecutive turns in one conversation, replaying prior user
              turns and this backend's assistant history, to verify multi-turn
              context on both backends. Each turn is persisted with evidence.
          verify --db PATH [--request ID]
              Independently recompute TTFT/wall/tokens from the stored raw wire
              evidence (LM Studio: exact request body + verbatim SSE lines;
              Apple: normalized event stream) and diff against recorded results.
              Exits 0 when every checked request verifies, 1 on any mismatch.
              This is the audit path: no metric has to be taken on trust.

        Everything runs on-device or on loopback. No cloud, ever.
        """)
    }

    // MARK: chat (multi-turn history verification)

    /// Consecutive turns in one conversation. This is the live proof for the
    /// history bugs: turn 2 must see turn 1's user text and *this backend's*
    /// assistant answer, exactly as the app coordinator builds envelopes.
    static func chat(_ arguments: [String]) async {
        var prompts: [String] = []
        var backends: [BackendID] = [.apple]
        var stateless = false
        var systemInstruction: String?
        var lmModel: String?
        var lmURL = LMStudioBackend.defaultBaseURL
        var dbPath: String?
        var options = SamplingOptions()

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            func value(_ name: String) -> String? {
                index + 1 < arguments.count ? arguments[index + 1] : nil
            }
            switch argument {
            case "--prompt":
                if let raw = value(argument) { prompts.append(raw) }
                index += 1
            case "--backends":
                if let raw = value(argument) {
                    backends = raw.split(separator: ",").compactMap { BackendID(rawValue: String($0).trimmingCharacters(in: .whitespaces)) }
                }
                index += 1
            case "--stateless": stateless = true
            case "--system": systemInstruction = value(argument); index += 1
            case "--lm-model": lmModel = value(argument); index += 1
            case "--lm-url":
                if let raw = value(argument) { lmURL = URL(string: raw) ?? LMStudioBackend.defaultBaseURL }
                index += 1
            case "--max-tokens":
                if let raw = value(argument) { options.maximumOutputTokens = Int(raw) }
                index += 1
            case "--temperature":
                if let raw = value(argument) { options.temperature = Double(raw) }
                index += 1
            case "--db": dbPath = value(argument); index += 1
            default:
                print("Unknown flag: \(argument)")
                exit(2)
            }
            index += 1
        }
        guard !prompts.isEmpty else {
            print("chat requires at least one --prompt")
            exit(2)
        }

        var backendMap: [BackendID: ChatBackend] = [:]
        if backends.contains(.apple) { backendMap[.apple] = AppleBackend() }
        if backends.contains(.lmStudio) {
            let (models, error) = await LMStudioBackend.discover(baseURL: lmURL)
            if let error { print("[lmstudio] unavailable: \(error.message)") }
            let selected = lmModel ?? models.first?.id
            if let selected {
                let capabilities = CapabilityReport(
                    text: true, streaming: true,
                    images: models.first { $0.id == selected }?.capabilities?.vision == true,
                    guidedGeneration: true, toolCalling: false, reasoning: false
                )
                backendMap[.lmStudio] = LMStudioBackend(baseURL: lmURL, modelID: selected, discoveredCapabilities: capabilities)
                print("[lmstudio] model=\(selected)")
            } else {
                print("[lmstudio] no model available")
            }
        }

        let storePath = dbPath ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalBench", isDirectory: true)
            .appendingPathComponent("localbench.sqlite").path)
        try? FileManager.default.createDirectory(atPath: (storePath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        var store: SQLiteStore?
        do {
            store = try SQLiteStore(path: storePath)
            print("db=\(storePath)")
        } catch {
            print("db FAILED: \(error)")
        }

        let conversationID = "chat-\(UUID().uuidString.prefix(8))"
        let conversation = Conversation(id: conversationID, title: prompts[0])
        try? store?.saveConversation(conversation)
        let recorder = MetricsRecorder()
        let identities = await identities(for: backendMap)

        var priorUserMessages: [String] = []
        var assistantHistory: [BackendID: [RequestEnvelope.AssistantMessage]] = [:]
        var turnIndex = 0

        for prompt in prompts {
            print("\n=== turn \(turnIndex) ===")
            print("user: \(prompt)")
            for backendID in backends.sorted(by: { $0.rawValue < $1.rawValue }) {
                guard let backend = backendMap[backendID] else { continue }
                let identity = identities[backendID]
                let envelope = RequestEnvelope(
                    conversationID: conversationID,
                    turnIndex: turnIndex,
                    canonicalUserText: prompt,
                    systemInstruction: systemInstruction,
                    priorUserMessages: priorUserMessages,
                    assistantHistory: stateless ? [] : (assistantHistory[backendID] ?? []),
                    options: options,
                    mode: stateless ? .stateless : .conversation,
                    schedule: .sequential
                )
                let capture = StreamCapture()
                if backendID == .apple {
                    capture.append(kind: .meta, data: "Apple FoundationModels exposes no user-facing wire protocol; trace evidence is the normalized event stream only (recorded by MetricsRecorder).")
                }
                let result = await recorder.record(
                    envelope: envelope,
                    backend: backendID,
                    modelID: identity?.modelID ?? backendID.rawValue,
                    identity: identity,
                    events: backend.stream(envelope, capture: capture),
                    repetitionIndex: turnIndex,
                    memorySampler: MemorySampler(),
                    capture: capture
                )
                let status = result.error.map { "ERROR \($0.kind.rawValue): \($0.message)" } ?? result.finishReason.rawValue
                print("[\(backendID.rawValue)] \(result.rawText.isEmpty ? "(no visible content)" : result.rawText)")
                print("[\(backendID.rawValue)] ttft=\(result.ttftMS.map { String(format: "%.0f", $0) } ?? "n/a")ms wall=\(String(format: "%.0f", result.wallMS))ms tokens=in=\(result.inputTokens.map(String.init) ?? "n/a") out=\(result.outputTokens.map(String.init) ?? "n/a") (\(result.tokenProvenance.rawValue)) status=\(status)")
                if !stateless, !result.rawText.isEmpty {
                    assistantHistory[backendID, default: []].append(.init(text: result.rawText))
                }

                if let store {
                    let turnID = "turn-\(conversationID)-\(turnIndex)"
                    do {
                        try store.saveTurn(
                            Turn(id: turnID, turnIndex: turnIndex, canonicalUserText: prompt,
                                 promptHash: envelope.promptHash, schedule: envelope.schedule, mode: envelope.mode),
                            conversationID: conversationID
                        )
                        try store.saveRequest(envelope: envelope, turnID: turnID, backend: backendID)
                        try store.saveResult(result)
                        try store.saveMetricSamples(result.memorySamples, requestID: envelope.requestID)
                        try store.saveTraces(capture.snapshot(), requestID: envelope.requestID)
                        if let identity { try store.saveIdentity(identity) }
                    } catch {
                        print("db persist FAILED: \(error)")
                    }
                }
            }
            priorUserMessages.append(prompt)
            turnIndex += 1
        }
        print("\nconversation=\(conversationID)")
    }

    private static func identities(for backends: [BackendID: ChatBackend]) async -> [BackendID: BackendIdentity] {
        var result: [BackendID: BackendIdentity] = [:]
        for (id, backend) in backends {
            let report = await backend.availabilityReport()
            if let identity = report.identity { result[id] = identity }
        }
        return result
    }

    // MARK: verify

    static func verify(_ arguments: [String]) async {
        var dbPath: String?
        var requestID: String?
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            func value(_ name: String) -> String? {
                index + 1 < arguments.count ? arguments[index + 1] : nil
            }
            switch argument {
            case "--db": dbPath = value(argument); index += 1
            case "--request": requestID = value(argument); index += 1
            default:
                print("Unknown flag: \(argument)")
                exit(2)
            }
            index += 1
        }
        guard let dbPath, FileManager.default.fileExists(atPath: dbPath) else {
            print("verify: --db PATH required and must exist")
            exit(2)
        }

        do {
            let store = try SQLiteStore(path: dbPath)
            struct Row {
                let id: String
                let backend: String
                let modelID: String?
                let ttftMS: Double?
                let wallMS: Double?
                let tps: Double?
                let inputTokens: Int?
                let outputTokens: Int?
                let provenance: String?
                let errorKind: String?
                let rawText: String?
            }
            var rows: [Row] = []
            try store.query(
                """
                SELECT r.id, r.backend, res.model_id, res.ttft_ms, res.wall_ms,
                       res.output_tokens_per_second, res.input_tokens, res.output_tokens,
                       res.token_provenance, res.error_kind, res.raw_text
                FROM requests r JOIN results res ON res.request_id = r.id
                WHERE (?1 IS NULL OR r.id = ?1)
                ORDER BY r.created_at
                """,
                bind: requestID.map { [SQLValue.text($0)] } ?? []
            ) { row in
                rows.append(Row(
                    id: row.text(0) ?? "",
                    backend: row.text(1) ?? "",
                    modelID: row.text(2),
                    ttftMS: row.double(3),
                    wallMS: row.double(4),
                    tps: row.double(5),
                    inputTokens: row.int(6),
                    outputTokens: row.int(7),
                    provenance: row.text(8),
                    errorKind: row.text(9),
                    rawText: row.text(10)
                ))
            }
            guard !rows.isEmpty else {
                print("verify: no persisted requests found\(requestID.map { " for id \($0)" } ?? "")")
                exit(1)
            }

            var failures = 0
            for row in rows {
                let records = try store.wireTraces(requestID: row.id)
                let expected = TraceVerifier.Expected(
                    modelID: row.modelID,
                    ttftMS: row.ttftMS,
                    wallMS: row.wallMS,
                    outputTokensPerSecond: row.tps,
                    inputTokens: row.inputTokens,
                    outputTokens: row.outputTokens,
                    tokenProvenance: row.provenance,
                    errorKind: row.errorKind,
                    rawText: row.rawText
                )
                let report = TraceVerifier.verify(records: records, expected: expected)
                if report.passed {
                    print("[PASS] \(row.id) \(row.backend) — \(records.count) records verify against recorded metrics")
                } else {
                    failures += 1
                    print("[FAIL] \(row.id) \(row.backend)")
                    for finding in report.findings {
                        print("       - \(finding)")
                    }
                }
            }
            print("verified \(rows.count) request(s), \(failures) failing")
            exit(failures == 0 ? 0 : 1)
        } catch {
            print("verify FAILED: \(error)")
            exit(1)
        }
    }

    // MARK: capabilities

    static func capabilities() async {
        print("=== LocalBench capability report ===")
        let environment = AppEnvironment.current()
        print("[env] os=\(environment.osVersion) build=\(environment.osBuild)")
        print("[env] chip=\(environment.chip) cores=\(environment.cpuCores) ram=\(environment.physicalMemoryGB)GB")
        print("[env] thermal=\(environment.thermalState) lowPower=\(environment.isLowPowerMode) power=\(environment.battery)")

        let apple = AppleBackend()
        let appleReport = await apple.availabilityReport()
        print("\n[apple] available=\(appleReport.isAvailable)")
        print("[apple] reason=\(appleReport.reason)")
        if let identity = appleReport.identity {
            print("[apple] model=\(identity.modelID)")
            print("[apple] contextSize=\(identity.contextSize.map(String.init) ?? "unavailable")")
            print("[apple] vision=\(identity.capabilities.images) guidedGeneration=\(identity.capabilities.guidedGeneration) toolCalling=\(identity.capabilities.toolCalling) reasoning=\(identity.capabilities.reasoning)")
        } else {
            print("[apple] advice=\(appleReport.actionableAdvice)")
        }

        let lmURL = LMStudioBackend.defaultBaseURL
        let (models, error) = await LMStudioBackend.discover(baseURL: lmURL)
        if let error {
            print("\n[lmstudio] unavailable: \(error.message)")
            print("[lmstudio] advice: start LM Studio's local server and load a model")
        } else {
            print("\n[lmstudio] reachable at \(lmURL.absoluteString)")
            for model in models {
                let vision = model.capabilities?.vision == true
                let tools = model.capabilities?.trainedForToolUse == true
                print("[lmstudio] model=\(model.id) vision=\(vision) toolUse=\(tools)")
            }
            if models.isEmpty {
                print("[lmstudio] no models loaded")
            }
        }
    }

    // MARK: run

    static func runBenchmark(_ arguments: [String]) async {
        var prompt: String?
        var backends: [BackendID] = [.apple, .lmStudio]
        var schedule = RunSchedule.sequential
        var reps = 1
        var stateless = false
        var prewarm = true
        var options = SamplingOptions()
        var systemInstruction: String?
        var attachments: [String] = []
        var lmModel: String?
        var lmURL = LMStudioBackend.defaultBaseURL
        var dbPath: String?
        var exportDir: String?
        var ocrAllowed = false

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            func value(_ name: String) -> String? {
                index + 1 < arguments.count ? arguments[index + 1] : nil
            }
            switch argument {
            case "--prompt": prompt = value(argument); index += 1
            case "--system": systemInstruction = value(argument); index += 1
            case "--backends":
                if let raw = value(argument) {
                    backends = raw.split(separator: ",").compactMap { BackendID(rawValue: String($0).trimmingCharacters(in: .whitespaces)) }
                }
                index += 1
            case "--schedule":
                if let raw = value(argument) { schedule = raw == "parallel" ? .parallel : .sequential }
                index += 1
            case "--reps":
                if let raw = value(argument) { reps = Int(raw) ?? 1 }
                index += 1
            case "--stateless": stateless = true
            case "--no-prewarm": prewarm = false
            case "--temperature":
                if let raw = value(argument) { options.temperature = Double(raw) }
                index += 1
            case "--max-tokens":
                if let raw = value(argument) { options.maximumOutputTokens = Int(raw) }
                index += 1
            case "--seed":
                if let raw = value(argument) { options.seed = UInt64(raw) }
                index += 1
            case "--attach":
                if let raw = value(argument) { attachments.append(raw) }
                index += 1
            case "--lm-model": lmModel = value(argument); index += 1
            case "--lm-url":
                if let raw = value(argument) { lmURL = URL(string: raw) ?? LMStudioBackend.defaultBaseURL }
                index += 1
            case "--db": dbPath = value(argument); index += 1
            case "--export-dir": exportDir = value(argument); index += 1
            case "--ocr": ocrAllowed = true
            default:
                print("Unknown flag: \(argument)")
                exit(2)
            }
            index += 1
        }

        guard let prompt else {
            print("Missing required --prompt")
            exit(2)
        }

        print("=== LocalBench run ===")
        print("prompt=\(prompt)")
        print("backends=\(backends.map { $0.rawValue }.joined(separator: ",")) schedule=\(schedule.rawValue) reps=\(reps) stateless=\(stateless) prewarm=\(prewarm)")

        // Prepare attachments (shared extraction, hashes, page provenance).
        var passages: [ExtractedPassage] = []
        var images: [PreparedImage] = []
        let pipeline = AttachmentPipeline()
        for path in attachments {
            let url = URL(fileURLWithPath: path)
            do {
                let prepared = try pipeline.prepare(fileURL: url, ocrAllowed: ocrAllowed)
                print("attach=\(prepared.filename) kind=\(prepared.kind.rawValue) sha256=\(prepared.sha256.prefix(12))… passages=\(prepared.passages.count) ocr=\(prepared.usedOCR)")
                passages.append(contentsOf: prepared.passages)
                if prepared.kind == .image {
                    if let imageResult = try? pipeline.prepareImageForModel(fileURL: url, ocrAllowed: ocrAllowed) {
                        images.append(imageResult.prepared)
                        if let resized = imageResult.prepared.resizedPixelWidth {
                            print("attach-image-resized=\(prepared.filename) \(imageResult.prepared.originalPixelWidth)x\(imageResult.prepared.originalPixelHeight) → \(resized)x\(imageResult.prepared.resizedPixelHeight ?? 0)")
                        }
                    }
                }
            } catch {
                print("attach FAILED=\(path) error=\(error)")
                exit(3)
            }
        }

        // Build backends.
        var backendMap: [BackendID: ChatBackend] = [:]
        if backends.contains(.apple) {
            backendMap[.apple] = AppleBackend()
        }
        if backends.contains(.lmStudio) {
            let (models, error) = await LMStudioBackend.discover(baseURL: lmURL)
            if let error {
                print("[lmstudio] unavailable: \(error.message)")
            }
            let selected = lmModel ?? models.first?.id
            if selected == nil {
                print("[lmstudio] no model available; LM Studio runs will be recorded as unavailable")
                backendMap[.lmStudio] = LMStudioBackend(baseURL: lmURL, modelID: "none", discoveredCapabilities: nil)
            }
            if let selected {
                let capabilities = CapabilityReport(text: true, streaming: true, images: models.first { $0.id == selected }?.capabilities?.vision == true, guidedGeneration: true, toolCalling: false, reasoning: false)
                backendMap[.lmStudio] = LMStudioBackend(baseURL: lmURL, modelID: selected, discoveredCapabilities: capabilities)
                print("[lmstudio] model=\(selected)")
            }
        }

        guard !backendMap.isEmpty else {
            print("No backends selected.")
            exit(2)
        }

        // Open the database BEFORE running so every request persists live —
        // traces survive even if the process dies mid-run.
        let storePath = dbPath ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalBench", isDirectory: true)
            .appendingPathComponent("localbench.sqlite").path)
        try? FileManager.default.createDirectory(atPath: (storePath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        var store: SQLiteStore?
        do {
            store = try SQLiteStore(path: storePath)
            print("db=\(storePath)")
        } catch {
            print("db FAILED: \(error)")
        }

        var runner = BenchmarkRunner(backends: backendMap, store: store)
        runner.onPersistenceError = { error in
            print("db persist FAILED: \(error)")
        }
        let configuration = BenchmarkRunner.Configuration(
            prompt: prompt,
            systemInstruction: systemInstruction,
            schedule: schedule,
            repetitions: reps,
            stateless: stateless,
            options: options,
            passages: passages,
            images: images,
            prewarm: prewarm
        )
        let run = await runner.run(configuration: configuration)

        // Persist the run row + aggregates (per-request rows were saved live).
        if let store {
            do {
                try store.saveBenchmarkRun(run)
            } catch {
                print("db run FAILED: \(error)")
            }
        }

        // Print per-run summary (real numbers only).
        for result in run.results.sorted(by: { $0.repetitionIndex < $1.repetitionIndex }) {
            let ttft = result.ttftMS.map { String(format: "%.0f", $0) } ?? "n/a"
            let wall = String(format: "%.0f", result.wallMS)
            let tps = result.outputTokensPerSecond.map { String(format: "%.1f", $0) } ?? "n/a"
            let tokens: String
            switch result.tokenProvenance {
            case .native, .server:
                tokens = "in=\(result.inputTokens ?? -1) out=\(result.outputTokens ?? -1) (\(result.tokenProvenance.rawValue))"
            default:
                tokens = "n/a (\(result.tokenProvenance.rawValue))"
            }
            let status = result.error.map { "ERROR \($0.kind.rawValue): \($0.message)" } ?? result.finishReason.rawValue
            print("[\(result.backend.rawValue)] rep\(result.repetitionIndex) warmth=\(result.warmth.rawValue) ttft=\(ttft)ms wall=\(wall)ms tps=\(tps) tokens=\(tokens) status=\(status)")
        }
        if let aggregates = run.aggregatesJSON { print("aggregates=\(aggregates)") }

        // Export.
        do {
            let directory = exportDir.map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            let baseName = "localbench-\(Int(Date().timeIntervalSince1970))"
            let (jsonURL, csvURL) = try ExportService.write(run: run, to: directory, fileBaseName: baseName)
            print("export.json=\(jsonURL.path)")
            print("export.csv=\(csvURL.path)")
        } catch {
            print("export FAILED: \(error)")
            exit(4)
        }
    }
}
