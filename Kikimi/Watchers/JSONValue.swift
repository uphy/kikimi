import Foundation

// MARK: - JSONValue

/// Order-preserving dynamic JSON value for Watcher state / LLM output, whose shape is entirely
/// user-defined per `WatcherSchema` (`docs/design/05-watcher-runner.md` §2.2).
///
/// Deliberately **not** `Codable`: `JSONDecoder.keyDecodingStrategy`/`JSONEncoder
/// .keyEncodingStrategy`'s `.convertFromSnakeCase`/`.convertToSnakeCase` apply to dictionary keys
/// too (not just `Decodable` struct properties), which would silently mangle a user-defined field
/// name like `source_seg_id` into `sourceSegId` and break the view template's variable lookup.
/// Parsing/serialization therefore goes through `JSONSerialization` (parsing) and a hand-written
/// serializer (writing, to preserve member order -- see `serialize(pretty:)`) instead of `Codable`
/// entirely.
///
/// `object` stores `[Member]`, not `[String: JSONValue]`, to preserve insertion order: the `{{state}}`
/// prompt placeholder (`WatcherPromptBuilder`) embeds this value's JSON text verbatim, and an
/// unstable member order across batches would needlessly perturb the LLM's input (§2.2).
/// `WatcherSchema.canonicalize(_:)` re-orders a schema-validated value into declaration order for the
/// entry points that need a *stable* order (parsed LLM output / persisted state), since
/// `JSONSerialization`-based parsing itself does not preserve source order.
indirect enum JSONValue: Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([Member])

    /// A single `object` entry. A plain tuple `(String, JSONValue)` cannot conform to `Equatable`
    /// (Swift does not synthesize tuple conformances), so `JSONValue`'s own derived `Equatable`
    /// conformance needs this struct instead (`docs/design/05-watcher-runner.md` §2.2).
    struct Member: Sendable, Equatable {
        var key: String
        var value: JSONValue
    }
}

// MARK: - JSONValueError

enum JSONValueError: LocalizedError, Equatable, Sendable {
    case invalidUTF8
    case unsupportedTopLevelType(String)

    var errorDescription: String? {
        switch self {
        case .invalidUTF8:
            return "JSON text was not valid UTF-8."
        case .unsupportedTopLevelType(let description):
            return "Unsupported JSON value type: \(description)."
        }
    }
}

// MARK: - Parsing

extension JSONValue {
    /// Parses `data` as JSON via `JSONSerialization`. Member order within any nested object is
    /// **not** preserved (a plain `[String: Any]` has no order) -- callers that need canonical order
    /// use `WatcherSchema.canonicalize(_:)` afterward.
    static func parse(data: Data) throws -> JSONValue {
        let raw = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return try fromJSONSerializationObject(raw)
    }

    /// Convenience over `parse(data:)` for callers holding a `String` (LLM raw JSON responses,
    /// `initial_state` frontmatter text).
    static func parse(string: String) throws -> JSONValue {
        guard let data = string.data(using: .utf8) else {
            throw JSONValueError.invalidUTF8
        }
        return try parse(data: data)
    }

    private static func fromJSONSerializationObject(_ raw: Any) throws -> JSONValue {
        switch raw {
        case is NSNull:
            return .null
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            // `JSONSerialization` boxes JSON `true`/`false` as `NSNumber` too (a `CFBoolean`), so
            // `Bool`-ness must be checked via `CFGetTypeID` before falling through to the
            // int/double split -- `NSNumber.boolValue` would otherwise happily (and wrongly) accept
            // any nonzero number.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            if CFNumberIsFloatType(number) {
                return .double(number.doubleValue)
            }
            return .int(number.intValue)
        case let array as [Any]:
            return .array(try array.map(fromJSONSerializationObject))
        case let dict as [String: Any]:
            var members: [Member] = []
            members.reserveCapacity(dict.count)
            for (key, value) in dict {
                members.append(Member(key: key, value: try fromJSONSerializationObject(value)))
            }
            return .object(members)
        default:
            throw JSONValueError.unsupportedTopLevelType(String(describing: type(of: raw)))
        }
    }
}

// MARK: - Serialization

extension JSONValue {
    /// Serializes this value to a JSON string, preserving `object` member order exactly as stored
    /// (`docs/design/05-watcher-runner.md` §2.2/§7.1: `WatcherRunner` writes
    /// `watchers/<id>.state.json` via this, not `JSONEncoder`). Hand-written rather than
    /// `JSONSerialization.data(withJSONObject:)`: an `NSDictionary` built from `[Member]` does not
    /// guarantee it re-serializes in insertion order, which would defeat the entire point of
    /// `object` being `[Member]` instead of `[String: JSONValue]`.
    func serialize(pretty: Bool) -> String {
        var output = ""
        if pretty {
            writePretty(to: &output, level: 0)
        } else {
            writeCompact(to: &output)
        }
        return output
    }

    private func writeCompact(to output: inout String) {
        switch self {
        case .null:
            output += "null"
        case .bool(let value):
            output += value ? "true" : "false"
        case .int(let value):
            output += String(value)
        case .double(let value):
            output += Self.format(double: value)
        case .string(let value):
            output += Self.escaped(value)
        case .array(let items):
            output += "["
            for (index, item) in items.enumerated() {
                if index > 0 { output += "," }
                item.writeCompact(to: &output)
            }
            output += "]"
        case .object(let members):
            output += "{"
            for (index, member) in members.enumerated() {
                if index > 0 { output += "," }
                output += Self.escaped(member.key)
                output += ":"
                member.value.writeCompact(to: &output)
            }
            output += "}"
        }
    }

    private func writePretty(to output: inout String, level: Int) {
        let indent = String(repeating: "  ", count: level)
        let childIndent = String(repeating: "  ", count: level + 1)
        switch self {
        case .null, .bool, .int, .double, .string:
            writeCompact(to: &output)
        case .array(let items):
            guard !items.isEmpty else {
                output += "[]"
                return
            }
            output += "[\n"
            for (index, item) in items.enumerated() {
                output += childIndent
                item.writePretty(to: &output, level: level + 1)
                output += index < items.count - 1 ? ",\n" : "\n"
            }
            output += indent + "]"
        case .object(let members):
            guard !members.isEmpty else {
                output += "{}"
                return
            }
            output += "{\n"
            for (index, member) in members.enumerated() {
                output += childIndent
                output += Self.escaped(member.key)
                output += ": "
                member.value.writePretty(to: &output, level: level + 1)
                output += index < members.count - 1 ? ",\n" : "\n"
            }
            output += indent + "}"
        }
    }

    private static func format(double value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 {
            return String(format: "%.1f", value)
        }
        return String(value)
    }

    private static func escaped(_ string: String) -> String {
        var result = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"":
                result += "\\\""
            case "\\":
                result += "\\\\"
            case "\n":
                result += "\\n"
            case "\r":
                result += "\\r"
            case "\t":
                result += "\\t"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04x", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        result += "\""
        return result
    }
}
