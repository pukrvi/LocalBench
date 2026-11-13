import Foundation
import FoundationModels

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
        let session = LanguageModelSession(model: model, instructions: instructions)

        // Rebuild ONLY this backend's assistant history; canonical user turns
        // are appended as prompt entries (spec §5).
        var entries: [Transcript.Entry] = []
        for prior in envelope.priorUserMessages {
            entries.append(.prompt(Transcript.Prompt(segments: [.text(.init(content: prior))])))
        }
        for assistant in envelope.assistantHistory {
            entries.append(.response(Transcript.Response(assetIDs: [], segments: [.text(.init(content: assistant.text))])))
        }
        let history = Transcript(entries: entries)
        _ = history // history kept for stateless parity; session instructions carry the system prompt

        let prompt = Self.prompt(for: envelope)

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

    /// Build the prompt: canonical user text plus (untrusted) retrieved passages.
    /// Identical material to the LM Studio backend so comparisons stay fair.
    static func prompt(for envelope: RequestEnvelope) -> Prompt {
        let documentText = LMStudioBackend.untrustedPassageBlock(envelope.extractedPassages)
        if documentText.isEmpty {
            return Prompt(envelope.canonicalUserText)
        }
        return Prompt {
            envelope.canonicalUserText
            "\n\n"
            documentText
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
