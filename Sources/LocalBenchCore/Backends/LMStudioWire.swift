import Foundation

/// A streaming chat backend. Both implementations emit the same normalized
/// StreamEvents so MetricsRecorder and storage never branch on backend type.
public protocol ChatBackend: Sendable {
    var id: BackendID { get }

    /// Runtime-detected availability + identity (never assumed at build time).
    func availabilityReport() async -> AvailabilityReport

    /// Stream a canonical request. Never falls back to another backend and
    /// never makes non-loopback network calls (spec §1).
    func stream(_ envelope: RequestEnvelope) -> AsyncThrowingStream<StreamEvent, Error>
}

public extension ChatBackend {
    /// Capture-aware stream. Default implementation ignores the capture — the
    /// normalized event stream is still recorded into it by MetricsRecorder.
    /// LM Studio overrides this to additionally record raw wire evidence
    /// (exact request body + verbatim SSE lines); Apple has no user-facing
    /// wire protocol, so its evidence is the normalized event stream only.
    func stream(_ envelope: RequestEnvelope, capture: StreamCapture?) -> AsyncThrowingStream<StreamEvent, Error> {
        stream(envelope)
    }
}

/// Wire types for LM Studio's OpenAI-compatible endpoints.
public enum LMStudioWire {
    public struct ModelEntry: Codable, Sendable, Hashable {
        public var id: String
        public var object: String?
        public var capabilities: Capabilities?

        public struct Capabilities: Codable, Sendable, Hashable {
            public var vision: Bool?
            public var trainedForToolUse: Bool?

            enum CodingKeys: String, CodingKey {
                case vision
                case trainedForToolUse = "trained_for_tool_use"
            }
        }
    }

    public struct ModelsResponse: Codable, Sendable {
        public var object: String?
        public var data: [ModelEntry]?
    }

    public struct ChatMessage: Codable, Sendable {
        public var role: String
        /// Either a plain string or OpenAI-style content parts (text/image).
        public var content: Content
        public var name: String?

        public enum Content: Codable, Sendable, Hashable {
            case text(String)
            case parts([Part])

            public struct Part: Codable, Sendable, Hashable {
                public var type: String
                public var text: String?
                public var imageURL: ImageURL?

                public struct ImageURL: Codable, Sendable, Hashable {
                    public var url: String
                    public init(url: String) { self.url = url }
                }

                enum CodingKeys: String, CodingKey {
                    case type, text
                    case imageURL = "image_url"
                }
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                switch self {
                case .text(let string): try container.encode(string)
                case .parts(let parts): try container.encode(parts)
                }
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let string = try? container.decode(String.self) {
                    self = .text(string)
                } else if let parts = try? container.decode([Part].self) {
                    self = .parts(parts)
                } else {
                    throw DecodingError.typeMismatch(
                        Content.self,
                        DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "content must be string or parts")
                    )
                }
            }
        }

        public init(role: String, text: String) {
            self.role = role
            self.content = .text(text)
        }

        public init(role: String, parts: [Content.Part]) {
            self.role = role
            self.content = .parts(parts)
        }
    }

    public struct ChatRequest: Codable, Sendable {
        public var model: String
        public var messages: [ChatMessage]
        public var stream: Bool
        public var streamOptions: StreamOptions?
        public var temperature: Double?
        public var maxTokens: Int?
        public var topP: Double?
        public var seed: Int?
        public var responseFormat: ResponseFormat?

        public struct StreamOptions: Codable, Sendable, Hashable {
            public var includeUsage: Bool

            enum CodingKeys: String, CodingKey {
                case includeUsage = "include_usage"
            }
        }

        public struct ResponseFormat: Codable, Sendable, Hashable {
            public var type: String
            public var jsonSchema: JSONSchema?

            enum CodingKeys: String, CodingKey {
                case type
                case jsonSchema = "json_schema"
            }
        }

        public struct JSONSchema: Codable, Sendable, Hashable {
            public var name: String
            public var schema: [String: AnyCodable]
        }

        enum CodingKeys: String, CodingKey {
            case model, messages, stream, temperature, seed
            case streamOptions = "stream_options"
            case maxTokens = "max_tokens"
            case topP = "top_p"
            case responseFormat = "response_format"
        }
    }

    /// Delta chunk from the stream.
    public struct StreamChunk: Codable, Sendable {
        public struct Choice: Codable, Sendable {
            public struct Delta: Codable, Sendable {
                public var content: String?
                public var reasoning: String?
            }
            public var index: Int?
            public var delta: Delta?
            public var finishReason: String?

            enum CodingKeys: String, CodingKey {
                case index, delta
                case finishReason = "finish_reason"
            }
        }
        public var id: String?
        public var model: String?
        public var choices: [Choice]?
        public var usage: Usage?
        public var error: ErrorPayload?
    }

    public struct Usage: Codable, Sendable, Hashable {
        public var promptTokens: Int?
        public var completionTokens: Int?
        public var totalTokens: Int?
        public var cachedTokens: Int?

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case totalTokens = "total_tokens"
            case cachedTokens = "cached_tokens"
        }
    }

    public struct ErrorPayload: Codable, Sendable, Hashable {
        public var message: String?
        public var type: String?
        public var code: String?
    }
}

/// Minimal `[String: Any]` codable shim for JSON schema passthrough.
public struct AnyCodable: Codable, Sendable, Hashable {
    public var value: AnyValue

    public enum AnyValue: Hashable, Sendable {
        case string(String)
        case number(Double)
        case bool(Bool)
        case null
        case array([AnyCodable])
        case dictionary([String: AnyCodable])
    }

    public init(_ value: AnyValue) { self.value = value }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) { value = .string(string) }
        else if let number = try? container.decode(Double.self) { value = .number(number) }
        else if let bool = try? container.decode(Bool.self) { value = .bool(bool) }
        else if container.decodeNil() { value = .null }
        else if let array = try? container.decode([AnyCodable].self) { value = .array(array) }
        else if let dict = try? container.decode([String: AnyCodable].self) { value = .dictionary(dict) }
        else { throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON value")) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case .string(let s): try container.encode(s)
        case .number(let n): try container.encode(n)
        case .bool(let b): try container.encode(b)
        case .null: try container.encodeNil()
        case .array(let a): try container.encode(a)
        case .dictionary(let d): try container.encode(d)
        }
    }

    public init(anyValue: Any) {
        switch anyValue {
        case let s as String: value = .string(s)
        case let n as NSNumber: value = .number(n.doubleValue)
        case let b as Bool: value = .bool(b)
        case is NSNull: value = .null
        case let array as [Any]: value = .array(array.map(AnyCodable.init(anyValue:)))
        case let dict as [String: Any]: value = .dictionary(dict.mapValues(AnyCodable.init(anyValue:)))
        default: value = .null
        }
    }

    public var jsonValue: Any {
        switch value {
        case .string(let s): return s
        case .number(let n): return n
        case .bool(let b): return b
        case .null: return NSNull()
        case .array(let a): return a.map { $0.jsonValue }
        case .dictionary(let d): return d.mapValues { $0.jsonValue }
        }
    }
}
