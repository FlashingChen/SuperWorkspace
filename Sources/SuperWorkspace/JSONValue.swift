import Foundation

/// Minimal JSON tree used by the project tool bridge. The agent sends loosely
/// typed arguments, so tools read fields by name instead of binding structs.
enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value):
            if value.rounded() == value, value.magnitude < 9_007_199_254_740_992 {
                try container.encode(Int64(value))
            } else {
                try container.encode(value)
            }
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }

    var numberValue: Double? {
        switch self {
        case let .number(value): return value.isFinite ? value : nil
        case let .string(value): return Double(value)
        case let .bool(value): return value ? 1 : 0
        default: return nil
        }
    }

    var intValue: Int? { numberValue.map { Int($0.rounded()) } }
    var stringValue: String? {
        switch self {
        case let .string(value): return value
        case let .number(value): return value.rounded() == value ? String(Int64(value)) : String(value)
        default: return nil
        }
    }
    var boolValue: Bool? {
        switch self {
        case let .bool(value): return value
        case let .number(value): return value != 0
        case let .string(value): return ["true", "1", "yes"].contains(value.lowercased())
        default: return nil
        }
    }
    var objectValue: [String: JSONValue]? {
        if case let .object(value) = self { return value }
        return nil
    }
    var arrayValue: [JSONValue]? {
        if case let .array(value) = self { return value }
        return nil
    }

    subscript(key: String) -> JSONValue? { objectValue?[key] }

    static func object(_ pairs: [(String, JSONValue)]) -> JSONValue {
        .object(Dictionary(uniqueKeysWithValues: pairs))
    }
}
