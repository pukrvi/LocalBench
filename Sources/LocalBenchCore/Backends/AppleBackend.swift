import Foundation
import FoundationModels
import CoreGraphics
import ImageIO

/// Apple on-device Foundation Models backend.
/// Every capability below is runtime-detected on this machine (see docs/capabilities.md);
/// unavailable features produce honest errors, never silent fallbacks.
public struct AppleBackend: ChatBackend {
    public var id: BackendID { .apple }

    private let model: SystemLanguageModel

    public init() {
        self.model = SystemLanguageModel.default
    }

    // MARK: Availability

    public func availabilityReport() async -> AvailabilityReport {
        let environment = AppEnvironment.current()
        func identity(available: Bool) -> BackendIdentity {
            var capabilities = CapabilityReport(text: available, streaming: available, images: false, guidedGeneration: false, toolCalling: false, reasoning: false)
            var contextSize: Int?
            var modelID = "unavailable"
            if #available(macOS 27.0, *) {
                let caps = model.capabilities
                capabilities = CapabilityReport(
                    text: available,
                    streaming: available,
                    images: caps.contains(.vision),
                    guidedGeneration: caps.contains(.guidedGeneration),
                    toolCalling: caps.contains(.toolCalling),
                    reasoning: caps.contains(.reasoning)
                )
                modelID = model.variant.displayName
                contextSize = model.contextSize
            } else if #available(macOS 26.4, *) {
                modelID = "AFM (26.4: contextSize known, variant/capabilities API absent)"
                contextSize = model.contextSize
            } else {
                modelID = "AFM (26.0–26.3: contextSize falls back to 4096)"
                contextSize = model.contextSize
            }
            return BackendIdentity(
                backend: .apple,
                modelID: modelID,
                displayName: "Apple Foundation Models",
                contextSize: contextSize,
                capabilities: capabilities,
                osVersion: environment.osVersion,
                osBuild: environment.osBuild
            )
        }

        switch model.availability {
        case .available:
            return AvailabilityReport(backend: .apple, isAvailable: true, reason: "available", actionableAdvice: "", identity: identity(available: true))
        case .unavailable(let reason):
            let (why, advice): (String, String)
            switch reason {
            case .deviceNotEligible:
                why = "deviceNotEligible"
                advice = "This Mac is not eligible for Apple Intelligence. System Settings → General → About."
            case .appleIntelligenceNotEnabled:
                why = "appleIntelligenceNotEnabled"
                advice = "Enable Apple Intelligence in System Settings → Apple Intelligence & Siri."
            case .modelNotReady:
                why = "modelNotReady"
                advice = "Apple's model assets are still downloading/initializing. Try again shortly."
            @unknown default:
                why = "unavailable(unknown)"
                advice = "Unknown Apple Intelligence state."
            }
            return AvailabilityReport(backend: .apple, isAvailable: false, reason: why, actionableAdvice: advice, identity: identity(available: false))
        @unknown default:
            return AvailabilityReport(backend: .apple, isAvailable: false, reason: "unknown", actionableAdvice: "Unknown availability state.", identity: identity(available: false))
        }
    }

    // MARK: Streaming

    public func stream(_ envelope: RequestEnvelope) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await self.performStream(envelope) { event in
                    continuation.yield(event)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func performStream(_ envelope: RequestEnvelope, yield: @escaping @Sendable (StreamEvent) -> Void) async {
        // The on-device model only. The PrivateCloudComputeLanguageModel in this
        // framework is intentionally never constructed (spec §1: on-device only).
        guard model.isAvailable else {
            let report = await availabilityReport()
            yield(.failed(backend: .apple, error: BackendError(kind: .unavailable, message: "Apple Foundation Models unavailable (\(report.reason))", underlying: report.actionableAdvice), at: Date()))
            return
        }

        yield(.started(backend: .apple, at: Date()))

        let instructions = envelope.systemInstruction ?? "You are a precise benchmark assistant."

        // Images are only accepted when this OS and model truly support vision.
        // Silently dropping them would misrepresent the benchmark.
        if !envelope.images.isEmpty {
            guard #available(macOS 27.0, *), model.capabilities.contains(.vision) else {
                yield(.failed(backend: .apple, error: BackendError(
                    kind: .unsupportedCapability,
                    message: "Apple Foundation Models on this OS does not advertise vision; image attachments are blocked."
                ), at: Date()))
                return
            }
            let decoded = envelope.images.compactMap { Self.cgImage(from: $0) }
            guard decoded.count == envelope.images.count else {
                yield(.failed(backend: .apple, error: BackendError(
                    kind: .unsupportedCapability,
                    message: "One or more image attachments could not be decoded as JPEG/PNG; nothing was sent to the model."
                ), at: Date()))
                return
            }
        }

        // Tool declarations must be expressible and supported; otherwise fail
        // honestly rather than running a different request than requested.
        var tools: [any Tool] = []
        if !envelope.tools.isEmpty {
            guard #available(macOS 27.0, *), model.capabilities.contains(.toolCalling) else {
                yield(.failed(backend: .apple, error: BackendError(
                    kind: .unsupportedCapability,
                    message: "Apple Foundation Models on this OS does not advertise tool calling; tool declarations are blocked."
                ), at: Date()))
                return
            }
            do {
                tools = try Self.foundationTools(for: envelope.tools)
            } catch {
                yield(.failed(backend: .apple, error: BackendError(
                    kind: .unsupportedCapability,
                    message: "A tool declaration cannot be expressed by FoundationModels",
                    underlying: String(describing: error)
                ), at: Date()))
                return
            }
        }

        // Rebuild this backend's transcript: canonical prior user turns plus
        // this backend's own assistant turns, interleaved in conversation
        // order, and pass it into the session so history is actually used.
        let transcript = Self.transcript(for: envelope, instructions: instructions)
        let session = LanguageModelSession(model: model, tools: tools, transcript: transcript)

        let prompt = Self.prompt(for: envelope)
        var emittedToolCallIDs = Set<String>()

        do {
            // Native token counting for the input side (26.4+), before generation.
            if #available(macOS 26.4, *) {
                do {
                    let inputTokens = try await model.tokenCount(for: prompt)
                    yield(.usage(backend: .apple, inputTokens: inputTokens, outputTokens: nil, cachedTokens: nil, reasoningTokens: nil, provenance: .native))
                } catch {
                    // tokenCount can throw for unsupported shapes; usage from the
                    // stream (27.0+) is the authoritative source anyway.
                }
            }

            var text = ""

            for try await snapshot in session.streamResponse(to: prompt, options: Self.generationOptions(for: envelope.options)) {
                let newText = snapshot.content
                if newText.count > text.count {
                    let delta = newText.suffix(newText.count - text.count)
                    text = newText
                    yield(.delta(backend: .apple, text: String(delta)))
                }
                if #available(macOS 27.0, *) {
                    for entry in snapshot.transcriptEntries {
                        guard case .toolCalls(let calls) = entry else { continue }
                        for call in calls where !emittedToolCallIDs.contains(call.id) {
                            emittedToolCallIDs.insert(call.id)
                            yield(.toolCall(backend: .apple, call: ToolCall(
                                id: call.id,
                                name: call.toolName,
                                argumentsJSON: call.arguments.jsonString
                            )))
                        }
                    }
                    let usage = snapshot.usage
                    yield(.usage(backend: .apple,
                                 inputTokens: usage.input.totalTokenCount,
                                 outputTokens: usage.output.totalTokenCount,
                                 cachedTokens: usage.input.cachedTokenCount,
                                 reasoningTokens: usage.output.reasoningTokenCount,
                                 provenance: .native))
                }
            }
            yield(.finished(backend: .apple, reason: .stop, at: Date()))
        } catch is CancellationError {
            yield(.failed(backend: .apple, error: .cancelled(), at: Date()))
        } catch {
            yield(.failed(backend: .apple, error: Self.map(error: error), at: Date()))
        }
    }

    /// Build the canonical user text plus (untrusted) retrieved passages.
    /// Identical material to the LM Studio backend so comparisons stay fair.
    static func promptText(for envelope: RequestEnvelope) -> String {
        let documentText = LMStudioBackend.untrustedPassageBlock(envelope.extractedPassages)
        if documentText.isEmpty {
            return envelope.canonicalUserText
        }
        return "\(envelope.canonicalUserText)\n\n\(documentText)"
    }

    /// Build the prompt: canonical text, untrusted passages, and — when the OS
    /// and model support vision — the actual image attachments, labeled with
    /// their filenames. The caller validates capability before generation.
    static func prompt(for envelope: RequestEnvelope) -> Prompt {
        let text = promptText(for: envelope)
        guard #available(macOS 27.0, *), !envelope.images.isEmpty else {
            return Prompt(text)
        }
        let attachments: [Attachment<ImageAttachmentContent>] = envelope.images.compactMap { image in
            guard let cgImage = cgImage(from: image) else { return nil }
            return Attachment(cgImage).label(image.filename)
        }
        guard attachments.count == envelope.images.count else {
            // performStream rejects undecodable images before reaching here;
            // never silently send a different request.
            return Prompt(text)
        }
        return Prompt {
            text
            attachments
        }
    }

    /// Rebuild the full conversation transcript. Canonical prior user turns
    /// and this backend's own assistant turns are interleaved in order; the
    /// current turn remains the separate `Prompt` passed to the session.
    static func transcript(for envelope: RequestEnvelope, instructions: String) -> Transcript {
        var entries: [Transcript.Entry] = [
            .instructions(Transcript.Instructions(
                segments: [.text(.init(content: instructions))],
                toolDefinitions: []
            ))
        ]
        let assistantHistory = envelope.mode == .conversation ? envelope.assistantHistory : []
        let pairCount = max(envelope.priorUserMessages.count, assistantHistory.count)
        for index in 0..<pairCount {
            if index < envelope.priorUserMessages.count {
                entries.append(.prompt(Transcript.Prompt(
                    segments: [.text(.init(content: envelope.priorUserMessages[index]))]
                )))
            }
            if index < assistantHistory.count {
                entries.append(.response(Transcript.Response(
                    assetIDs: [],
                    segments: [.text(.init(content: assistantHistory[index].text))]
                )))
            }
        }
        return Transcript(entries: entries)
    }

    static func cgImage(from image: PreparedImage) -> CGImage? {
        let data = Data(image.jpegBytes)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    @available(macOS 27.0, *)
    static func foundationTools(for definitions: [ToolDefinition]) throws -> [any Tool] {
        try definitions.map { definition in
            let schema = try generationSchema(for: definition)
            return DeclaredTool(
                name: definition.name,
                description: definition.description,
                parameters: schema
            )
        }
    }

    enum ToolSchemaError: Error, Sendable {
        case invalidJSON(String)
        case unsupportedType(tool: String, type: String)
    }

    @available(macOS 27.0, *)
    static func generationSchema(for definition: ToolDefinition) throws -> GenerationSchema {
        guard let object = definition.parametersObject else {
            throw ToolSchemaError.invalidJSON(definition.name)
        }
        let root = try dynamicSchema(from: object, name: definition.name, tool: definition.name)
        return try GenerationSchema(root: root, dependencies: [])
    }

    @available(macOS 27.0, *)
    static func dynamicSchema(from json: [String: Any], name: String, tool: String) throws -> DynamicGenerationSchema {
        let type = (json["type"] as? String) ?? "object"
        switch type {
        case "object":
            let properties = json["properties"] as? [String: Any] ?? [:]
            let required = Set(json["required"] as? [String] ?? [])
            var list: [DynamicGenerationSchema.Property] = []
            for key in properties.keys.sorted() {
                guard let sub = properties[key] as? [String: Any] else {
                    throw ToolSchemaError.invalidJSON(tool)
                }
                let schema = try dynamicSchema(from: sub, name: "\(name)_\(key)", tool: tool)
                list.append(.init(
                    name: key,
                    description: sub["description"] as? String,
                    schema: schema,
                    isOptional: !required.contains(key)
                ))
            }
            return DynamicGenerationSchema(name: name, description: json["description"] as? String, properties: list)
        case "array":
            guard let items = json["items"] as? [String: Any] else {
                throw ToolSchemaError.invalidJSON(tool)
            }
            return DynamicGenerationSchema(arrayOf: try dynamicSchema(from: items, name: "\(name)_item", tool: tool))
        case "string":
            if let choices = json["enum"] as? [String], !choices.isEmpty {
                return DynamicGenerationSchema(name: name, anyOf: choices)
            }
            return DynamicGenerationSchema(type: String.self)
        case "integer":
            return DynamicGenerationSchema(type: Int.self)
        case "number":
            return DynamicGenerationSchema(type: Double.self)
        case "boolean":
            return DynamicGenerationSchema(type: Bool.self)
        default:
            throw ToolSchemaError.unsupportedType(tool: tool, type: type)
        }
    }

    /// Tool declarations are passed to FoundationModels so the model can emit
    /// structured calls. LocalBench does not execute arbitrary tools: calls are
    /// surfaced as `.toolCall` events and the model receives an explicit
    /// refusal instead of a fabricated result.
    @available(macOS 27.0, *)
    struct DeclaredTool: Tool {
        typealias Arguments = GeneratedContent
        typealias Output = String

        let name: String
        let description: String
        let parameters: GenerationSchema

        func call(arguments: GeneratedContent) async throws -> String {
            "TOOL_EXECUTION_DISABLED: LocalBench records tool invocations for verification but does not execute local tools."
        }
    }

    /// Map GenerationOptions; record what the framework supports.
    static func generationOptions(for options: SamplingOptions) -> GenerationOptions {
        var generation = GenerationOptions()
        if let temperature = options.temperature {
            generation.temperature = temperature
        }
        if let maximum = options.maximumOutputTokens {
            generation.maximumResponseTokens = maximum
        }
        // Seed is NOT supported by FoundationModels (no seed parameter exists).
        // SamplingMode.random(top:seed:) exists but a fixed seed parameter is not
        // exposed by the user-facing GenerationOptions here; greedy mode is used
        // when a seed is requested to keep runs reproducible.
        if options.seed != nil {
            generation.samplingMode = .greedy
        }
        return generation
    }

    static func map(error: Error) -> BackendError {
        if #available(macOS 27.0, *) {
            if let afmError = error as? LanguageModelError {
                switch afmError {
                case .contextSizeExceeded(let details):
                    return BackendError(kind: .contextTooLong,
                                        message: "Context exceeded (contextSize \(details.contextSize), prompt \(details.tokenCount) tokens)")
                case .rateLimited:
                    return BackendError(kind: .serverError, message: "Apple rate limit")
                case .guardrailViolation:
                    return BackendError(kind: .serverError, message: "Guardrail violation")
                case .refusal(let refusal):
                    // NB: refusal.explanation is an async model call (Response<String>);
                    // never trigger extra inference just to format an error.
                    return BackendError(kind: .serverError, message: "Model refusal", underlying: refusal.debugDescription)
                case .unsupportedCapability(let capability):
                    return BackendError(kind: .unsupportedCapability, message: "Unsupported capability: \(capability)")
                case .unsupportedLanguageOrLocale:
                    return BackendError(kind: .unsupportedCapability, message: "Language/locale unsupported by the model")
                case .timeout:
                    return BackendError(kind: .timeout, message: "Generation timed out")
                case .unsupportedGenerationGuide:
                    return BackendError(kind: .unsupportedCapability, message: "Unsupported generation guide")
                case .unsupportedTranscriptContent:
                    return BackendError(kind: .unsupportedCapability, message: "Unsupported transcript content")
                @unknown default:
                    return BackendError(kind: .unknown, message: "FoundationModels error")
                }
            }
        }
        return BackendError(kind: .unknown, message: String(describing: error))
    }
}
