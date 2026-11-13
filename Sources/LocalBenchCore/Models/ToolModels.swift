import Foundation

/// A tool/function declaration sent to a backend for native tool calling.
///
/// The schema is carried as a JSON object string exactly as the caller wrote
/// it: LocalBench never rewrites or "repairs" a schema, so what the model sees
/// is auditable. Backends that cannot express a declaration fail honestly
/// instead of silently ignoring it.
public struct ToolDefinition: Codable, Sendable, Hashable, Identifiable {
    public var name: String
    public var description: String
    /// A JSON object describing the tool's parameters (JSON Schema subset).
    public var parametersJSONSchema: String

    public var id: String { name }

    public init(name: String, description: String, parametersJSONSchema: String = #"{"type":"object","properties":{}}"#) {
        self.name = name
        self.description = description
        self.parametersJSONSchema = parametersJSONSchema
    }

    /// Validated schema object, or nil when the string is not a JSON object.
    public var parametersObject: [String: Any]? {
        guard let data = parametersJSONSchema.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }
}

/// One structured tool invocation reported by a backend.
public struct ToolCall: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    /// Argument fragments stitched into one JSON string (LM Studio streams
    /// arguments in pieces; Apple reports them as generated content).
    public var argumentsJSON: String

    public init(id: String, name: String, argumentsJSON: String) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Tolerate JSON-string arguments or raw JSON object arguments.
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        if let string = try? container.decode(String.self, forKey: .argumentsJSON) {
            self.argumentsJSON = string
        } else if let object = try? container.decode([String: AnyCodable].self, forKey: .argumentsJSON) {
            let data = try JSONEncoder().encode(object)
            self.argumentsJSON = String(decoding: data, as: UTF8.self)
        } else {
            self.argumentsJSON = "{}"
        }
    }
}