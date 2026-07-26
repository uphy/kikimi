import Foundation
import Yams

// MARK: - WatcherSchema

/// A Watcher's `schema:` frontmatter type declaration, parsed into a Swift model
/// (`docs/design/05-watcher-runner.md` §2.3), kikimi.md 9 章's "schema の型記法". The top level is
/// always an object (kikimi.md 9 章's `schema:` example is always a mapping of field name -> type).
struct WatcherSchema: Sendable, Equatable {
    var fields: [Field]

    struct Field: Sendable, Equatable {
        var name: String
        var type: FieldType
        /// Trailing `?` (scalar/enum types only; §2.3 "`?` は scalar / enum のみ").
        var nullable: Bool
    }

    indirect enum FieldType: Sendable, Equatable {
        case string, int, float, bool
        case enumeration([String])
        case array(FieldType)
        case object([Field])
    }
}

// MARK: - WatcherSchemaParseError

enum WatcherSchemaParseError: LocalizedError, Equatable, Sendable {
    case schemaMustBeMapping
    case invalidFieldName
    case arrayMustHaveExactlyOneElement(count: Int)
    case unknownScalarType(String)
    case invalidEnumDeclaration(String)
    case invalidNode

    var errorDescription: String? {
        switch self {
        case .schemaMustBeMapping:
            return "A Watcher schema (or a nested object field) must be a YAML mapping."
        case .invalidFieldName:
            return "A schema field's key must be a plain string."
        case .arrayMustHaveExactlyOneElement(let count):
            return "A schema array declaration must have exactly one element (found \(count))."
        case .unknownScalarType(let raw):
            return "Unknown schema scalar type \"\(raw)\". Expected string/int/float/bool/enum[...]."
        case .invalidEnumDeclaration(let raw):
            return "Invalid enum declaration \"\(raw)\": expected enum[a, b, ...] with at least one non-empty value."
        case .invalidNode:
            return "A schema field's value must be a scalar, mapping, or single-element sequence."
        }
    }
}

// MARK: - Parsing (§2.3)

extension WatcherSchema {
    /// Parses a `schema:` frontmatter YAML node (already `Yams.compose`d by the caller) into a
    /// `WatcherSchema`. `node` must be a `.mapping` (§2.3's "YAML の形 -> 解釈" table: the top level of
    /// a Watcher's `schema:` is always an object).
    static func parse(node: Node) throws -> WatcherSchema {
        guard case .mapping(let mapping) = node else {
            throw WatcherSchemaParseError.schemaMustBeMapping
        }
        return WatcherSchema(fields: try parseFields(from: mapping))
    }

    private static func parseFields(from mapping: Node.Mapping) throws -> [Field] {
        var fields: [Field] = []
        fields.reserveCapacity(mapping.count)
        for (keyNode, valueNode) in mapping {
            guard let name = keyNode.string else {
                throw WatcherSchemaParseError.invalidFieldName
            }
            let (type, nullable) = try parseFieldTypeAndNullability(from: valueNode)
            fields.append(Field(name: name, type: type, nullable: nullable))
        }
        return fields
    }

    private static func parseFieldTypeAndNullability(from node: Node) throws -> (FieldType, Bool) {
        switch node {
        case .scalar(let scalar):
            return try parseScalarType(scalar.string)
        case .mapping(let mapping):
            return (.object(try parseFields(from: mapping)), false)
        case .sequence(let sequence):
            let elements = Array(sequence)
            guard elements.count == 1 else {
                throw WatcherSchemaParseError.arrayMustHaveExactlyOneElement(count: elements.count)
            }
            let (elementType, _) = try parseFieldTypeAndNullability(from: elements[0])
            return (.array(elementType), false)
        case .alias:
            throw WatcherSchemaParseError.invalidNode
        }
    }

    private static func parseScalarType(_ raw: String) throws -> (FieldType, Bool) {
        var text = raw.trimmingCharacters(in: .whitespaces)
        let nullable = text.hasSuffix("?")
        if nullable {
            text.removeLast()
        }
        switch text {
        case "string":
            return (.string, nullable)
        case "int":
            return (.int, nullable)
        case "float":
            return (.float, nullable)
        case "bool":
            return (.bool, nullable)
        default:
            if text.hasPrefix("enum[") && text.hasSuffix("]") {
                let inner = text.dropFirst("enum[".count).dropLast()
                let values = inner.split(separator: ",", omittingEmptySubsequences: false).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                guard !values.isEmpty, values.allSatisfy({ !$0.isEmpty }) else {
                    throw WatcherSchemaParseError.invalidEnumDeclaration(raw)
                }
                return (.enumeration(values), nullable)
            }
            throw WatcherSchemaParseError.unknownScalarType(raw)
        }
    }
}

// MARK: - JSON Schema generation (§2.4)

extension WatcherSchema {
    /// Renders this schema as a JSON Schema string for `LLMRequest.schema` (§2.4), matching
    /// `SummaryJSONSchema`'s convention: `additionalProperties: false` and every field `required`
    /// (LLM must return a complete object; nullable fields simply allow `null` as their value).
    /// Property/required order follows `fields`' declaration order (deterministic, for prompt-cache
    /// and diff stability) -- built as a `JSONValue` tree specifically so `JSONValue.serialize(pretty:)`'s
    /// order-preserving writer produces this ordering, rather than routing through
    /// `JSONSerialization` (whose `[String: Any]` does not preserve insertion order).
    func jsonSchemaString() -> String {
        objectSchemaValue(forFields: fields).serialize(pretty: false)
    }

    private func objectSchemaValue(forFields fields: [Field]) -> JSONValue {
        var properties: [JSONValue.Member] = []
        var required: [JSONValue] = []
        properties.reserveCapacity(fields.count)
        required.reserveCapacity(fields.count)
        for field in fields {
            properties.append(JSONValue.Member(key: field.name, value: schemaValue(for: field.type, nullable: field.nullable)))
            required.append(.string(field.name))
        }
        return .object([
            .init(key: "type", value: .string("object")),
            .init(key: "properties", value: .object(properties)),
            .init(key: "required", value: .array(required)),
            .init(key: "additionalProperties", value: .bool(false))
        ])
    }

    private func schemaValue(for type: FieldType, nullable: Bool) -> JSONValue {
        switch type {
        case .string:
            return scalarSchemaValue(typeName: "string", nullable: nullable)
        case .int:
            return scalarSchemaValue(typeName: "integer", nullable: nullable)
        case .float:
            return scalarSchemaValue(typeName: "number", nullable: nullable)
        case .bool:
            return scalarSchemaValue(typeName: "boolean", nullable: nullable)
        case .enumeration(let values):
            let typeValue: JSONValue = nullable ? .array([.string("string"), .string("null")]) : .string("string")
            var enumValues = values.map(JSONValue.string)
            if nullable {
                enumValues.append(.null)
            }
            return .object([
                .init(key: "type", value: typeValue),
                .init(key: "enum", value: .array(enumValues))
            ])
        case .array(let elementType):
            return .object([
                .init(key: "type", value: .string("array")),
                .init(key: "items", value: schemaValue(for: elementType, nullable: false))
            ])
        case .object(let nestedFields):
            return objectSchemaValue(forFields: nestedFields)
        }
    }

    private func scalarSchemaValue(typeName: String, nullable: Bool) -> JSONValue {
        let typeValue: JSONValue = nullable ? .array([.string(typeName), .string("null")]) : .string(typeName)
        return .object([.init(key: "type", value: typeValue)])
    }
}

// MARK: - Validation (§2.4)

extension WatcherSchema {
    /// Validates `value` against this schema, returning every mismatch found (empty = valid). Used
    /// both for LLM output (defensive re-check even though the backend enforces the schema) and for
    /// a persisted `watchers/<id>.state.json` loaded at startup (§7.1's "schema 変更で既存 state の
    /// バリデーションが落ちた場合は initial_state にリセット"). `int` also accepts a whole-number
    /// `.double` and `float` also accepts `.int` (§2.4: "int は小数部のない number も許容、float は int も
    /// 許容").
    func validate(_ value: JSONValue) -> [String] {
        validateObject(value, fields: fields, path: "$")
    }

    private func validateObject(_ value: JSONValue, fields: [Field], path: String) -> [String] {
        guard case .object(let members) = value else {
            return ["\(path): expected an object"]
        }
        let byKey = Dictionary(members.map { ($0.key, $0.value) }, uniquingKeysWith: { _, last in last })
        var errors: [String] = []
        for field in fields {
            guard let fieldValue = byKey[field.name] else {
                errors.append("\(path).\(field.name): missing required field")
                continue
            }
            errors.append(contentsOf: validateFieldValue(fieldValue, field: field, path: "\(path).\(field.name)"))
        }
        return errors
    }

    private func validateFieldValue(_ value: JSONValue, field: Field, path: String) -> [String] {
        if case .null = value {
            return field.nullable ? [] : ["\(path): null is not allowed for this field"]
        }
        return validateTypedValue(value, type: field.type, path: path)
    }

    private func validateTypedValue(_ value: JSONValue, type: FieldType, path: String) -> [String] {
        switch type {
        case .string:
            if case .string = value { return [] }
            return ["\(path): expected a string"]
        case .int:
            switch value {
            case .int:
                return []
            case .double(let doubleValue) where doubleValue.truncatingRemainder(dividingBy: 1) == 0:
                return []
            default:
                return ["\(path): expected an int"]
            }
        case .float:
            switch value {
            case .double, .int:
                return []
            default:
                return ["\(path): expected a float"]
            }
        case .bool:
            if case .bool = value { return [] }
            return ["\(path): expected a bool"]
        case .enumeration(let values):
            if case .string(let stringValue) = value, values.contains(stringValue) { return [] }
            return ["\(path): expected one of \(values.joined(separator: ", "))"]
        case .array(let elementType):
            guard case .array(let items) = value else {
                return ["\(path): expected an array"]
            }
            return items.enumerated().flatMap { index, item in
                validateTypedValue(item, type: elementType, path: "\(path)[\(index)]")
            }
        case .object(let nestedFields):
            return validateObject(value, fields: nestedFields, path: path)
        }
    }
}

// MARK: - Canonicalization (§2.2)

extension WatcherSchema {
    /// Reorders `value`'s object members (recursively, through nested objects and arrays of objects
    /// too) into this schema's declared field order (§2.2's "順序が必要な入口では schema のフィールド宣言順
    /// に並べ直す"). Intended for use only after `validate(_:)` has already passed: a field this
    /// schema doesn't declare is dropped from the result (defensive; should not occur for
    /// schema-validated input), and a declared field missing from `value` is simply omitted (should
    /// also not occur post-validation, since `validate` requires every field present).
    func canonicalize(_ value: JSONValue) -> JSONValue {
        canonicalizeObject(value, fields: fields)
    }

    private func canonicalizeObject(_ value: JSONValue, fields: [Field]) -> JSONValue {
        guard case .object(let members) = value else { return value }
        let byKey = Dictionary(members.map { ($0.key, $0.value) }, uniquingKeysWith: { _, last in last })
        var result: [JSONValue.Member] = []
        result.reserveCapacity(fields.count)
        for field in fields {
            guard let fieldValue = byKey[field.name] else { continue }
            result.append(JSONValue.Member(key: field.name, value: canonicalizeFieldValue(fieldValue, type: field.type)))
        }
        return .object(result)
    }

    private func canonicalizeFieldValue(_ value: JSONValue, type: FieldType) -> JSONValue {
        switch type {
        case .object(let nestedFields):
            return canonicalizeObject(value, fields: nestedFields)
        case .array(let elementType):
            guard case .array(let items) = value else { return value }
            return .array(items.map { canonicalizeFieldValue($0, type: elementType) })
        case .string, .int, .float, .bool, .enumeration:
            return value
        }
    }
}
