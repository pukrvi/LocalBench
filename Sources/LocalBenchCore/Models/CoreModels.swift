import Foundation

/// Which inference backend a request or result belongs to.
public enum BackendID: String, Codable, Sendable, CaseIterable, Hashable {
    case apple
    case lmStudio = "lmstudio"

    public var displayName: String {
        switch self {
        case .apple: return "Apple (Foundation Models)"
        case .lmStudio: return "LM Studio"
        }
    }
}

/// Why a generation ended.
public enum FinishReason: String, Codable, Sendable, Hashable {
    case stop
    case length
    case cancelled
    case error
    case toolCalls = "tool_calls"
    case contentFilter = "content_filter"
    case unknown
}

/// Where a token count came from. Never present an exact-looking number
/// without stating its provenance (spec §6).
public enum TokenProvenance: String, Codable, Sendable, Hashable {
    /// Reported by Apple FoundationModels (Usage / tokenCount(for:)).
    case native
    /// Reported by the LM Studio server (usage chunk).
    case server
    /// Explicitly labeled approximation; never shown as an exact count.
    case estimated
    /// Unknown; UI must show "unavailable".
    case unavailable
}

public enum RunSchedule: String, Codable, Sendable, Hashable {
    case sequential
    case parallel
}

public enum RunMode: String, Codable, Sendable, Hashable {
    /// Conversation with per-backend isolated assistant history.
    case conversation
    /// Same system instruction + prompt, no assistant history (single-turn benchmark).
    case stateless
}

/// Cold/warm labeling for repeatable benchmarks (spec §5).
public enum WarmthLabel: String, Codable, Sendable, Hashable {
    case cold
    case warm
    case unknown
}

/// Sampling controls; both backends honor what they support and the rest is
/// recorded as unsupported rather than silently ignored.
public struct SamplingOptions: Codable, Sendable, Hashable {
    public var temperature: Double?
    public var maximumOutputTokens: Int?
    public var seed: UInt64?
    /// Guided-generation request, e.g. a JSON schema (backend-dependent).
    public var jsonSchema: String?

    public init(temperature: Double? = nil,
                maximumOutputTokens: Int? = nil,
                seed: UInt64? = nil,
                jsonSchema: String? = nil) {
        self.temperature = temperature
        self.maximumOutputTokens = maximumOutputTokens
        self.seed = seed
        self.jsonSchema = jsonSchema
    }
}

/// A passage extracted from a local document, with page provenance.
public struct ExtractedPassage: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var documentName: String
    public var pageNumber: Int?
    public var charOffset: Int
    public var charLength: Int
    public var text: String
    public var sha256: String?

    public init(id: String = UUID().uuidString,
                documentName: String,
                pageNumber: Int? = nil,
                charOffset: Int,
                charLength: Int,
                text: String,
                sha256: String? = nil) {
        self.id = id
        self.documentName = documentName
        self.pageNumber = pageNumber
        self.charOffset = charOffset
        self.charLength = charLength
        self.text = text
        self.sha256 = sha256
    }
}

/// An image prepared for multimodal input. JPEG bytes; resizing is disclosed
/// to the user before send (spec §7).
public struct PreparedImage: Codable, Sendable, Hashable {
    public var filename: String
    public var sha256: String
    public var jpegBytes: [UInt8]
    public var originalPixelWidth: Int
    public var originalPixelHeight: Int
    public var resizedPixelWidth: Int?
    public var resizedPixelHeight: Int?
    /// OCR text, if the user approved local OCR.
    public var ocrText: String?

    public init(filename: String,
                sha256: String,
                jpegBytes: [UInt8],
                originalPixelWidth: Int,
                originalPixelHeight: Int,
                resizedPixelWidth: Int? = nil,
                resizedPixelHeight: Int? = nil,
                ocrText: String? = nil) {
        self.filename = filename
        self.sha256 = sha256
        self.jpegBytes = jpegBytes
        self.originalPixelWidth = originalPixelWidth
        self.originalPixelHeight = originalPixelHeight
        self.resizedPixelWidth = resizedPixelWidth
        self.resizedPixelHeight = resizedPixelHeight
        self.ocrText = ocrText
    }
}

/// Canonical request sent to every selected backend. Prior user messages and
/// extracted passages are identical across backends; assistant history is
/// backend-specific (spec §5).
public struct RequestEnvelope: Codable, Sendable, Hashable {
    public var requestID: String
    public var conversationID: String
    public var turnIndex: Int
    public var canonicalUserText: String
    public var systemInstruction: String?
    /// Canonical prior user turns (identical for every backend).
    public var priorUserMessages: [String]
    /// Assistant history from THIS backend only; empty in stateless mode.
    public var assistantHistory: [AssistantMessage]
    public var extractedPassages: [ExtractedPassage]
    public var attachmentSHA256s: [String]
    public var images: [PreparedImage]
    /// Native tool/function declarations. Empty = no tool calling.
    public var tools: [ToolDefinition]
    public var options: SamplingOptions
    public var mode: RunMode
    public var schedule: RunSchedule
    public var createdAt: Date

    public struct AssistantMessage: Codable, Sendable, Hashable {
        public var text: String
        public init(text: String) { self.text = text }
    }

    /// SHA-256 of the reproducible prompt material (canonical text + passages + options).
    public var promptHash: String {
        let material = """
        canonical:\(canonicalUserText)
        system:\(systemInstruction ?? "")
        passages:\(extractedPassages.map { "\($0.documentName)#\($0.pageNumber ?? -1)#\($0.charOffset)" }.joined(separator: "|"))
        options:\(options)
        images:\(attachmentSHA256s.joined(separator: ","))
        tools:\(tools.map { "\($0.name):\($0.parametersJSONSchema)" }.joined(separator: "|"))
        """
        return Sha256.hex(material)
    }

    public init(requestID: String = UUID().uuidString,
                conversationID: String,
                turnIndex: Int,
                canonicalUserText: String,
                systemInstruction: String? = nil,
                priorUserMessages: [String] = [],
                assistantHistory: [AssistantMessage] = [],
                extractedPassages: [ExtractedPassage] = [],
                attachmentSHA256s: [String] = [],
                images: [PreparedImage] = [],
                tools: [ToolDefinition] = [],
                options: SamplingOptions = SamplingOptions(),
                mode: RunMode = .conversation,
                schedule: RunSchedule = .sequential,
                createdAt: Date = Date()) {
        self.requestID = requestID
        self.conversationID = conversationID
        self.turnIndex = turnIndex
        self.canonicalUserText = canonicalUserText
        self.systemInstruction = systemInstruction
        self.priorUserMessages = priorUserMessages
        self.assistantHistory = assistantHistory
        self.extractedPassages = extractedPassages
        self.attachmentSHA256s = attachmentSHA256s
        self.images = images
        self.tools = tools
        self.options = options
        self.mode = mode
        self.schedule = schedule
        self.createdAt = createdAt
    }
}

/// Backend-reported identity and capability snapshot. Fields that a backend
/// does not expose are nil — the UI renders "unavailable", not guesses.
public struct BackendIdentity: Codable, Sendable, Hashable {
    public var backend: BackendID
    public var modelID: String
    public var displayName: String
    public var contextSize: Int?
    public var capabilities: CapabilityReport
    public var osVersion: String
    public var osBuild: String
    public var capturedAt: Date

    public init(backend: BackendID,
                modelID: String,
                displayName: String,
                contextSize: Int? = nil,
                capabilities: CapabilityReport,
                osVersion: String,
                osBuild: String,
                capturedAt: Date = Date()) {
        self.backend = backend
        self.modelID = modelID
        self.displayName = displayName
        self.contextSize = contextSize
        self.capabilities = capabilities
        self.osVersion = osVersion
        self.osBuild = osBuild
        self.capturedAt = capturedAt
    }
}

public struct CapabilityReport: Codable, Sendable, Hashable {
    public var text: Bool
    public var streaming: Bool
    public var images: Bool
    public var guidedGeneration: Bool
    public var toolCalling: Bool
    public var reasoning: Bool
    /// Server token usage in streaming responses (LM Studio).
    public var streamUsage: Bool?
    public var notes: [String]

    public init(text: Bool,
                streaming: Bool,
                images: Bool,
                guidedGeneration: Bool,
                toolCalling: Bool,
                reasoning: Bool,
                streamUsage: Bool? = nil,
                notes: [String] = []) {
        self.text = text
        self.streaming = streaming
        self.images = images
        self.guidedGeneration = guidedGeneration
        self.toolCalling = toolCalling
        self.reasoning = reasoning
        self.streamUsage = streamUsage
        self.notes = notes
    }
}

/// Why a backend cannot run right now, in user-actionable terms.
public struct AvailabilityReport: Codable, Sendable, Hashable {
    public var backend: BackendID
    public var isAvailable: Bool
    public var reason: String
    public var actionableAdvice: String
    public var identity: BackendIdentity?

    public init(backend: BackendID,
                isAvailable: Bool,
                reason: String,
                actionableAdvice: String,
                identity: BackendIdentity? = nil) {
        self.backend = backend
        self.isAvailable = isAvailable
        self.reason = reason
        self.actionableAdvice = actionableAdvice
        self.identity = identity
    }
}
