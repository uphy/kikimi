import Foundation
import Testing

@testable import Kikimi

/// Layer 1 coverage for `JSONValue` (`docs/design/05-watcher-runner.md` §2.2): parse/serialize
/// round-trips, and specifically that snake_case keys survive untouched (the entire reason this type
/// exists instead of routing dynamic Watcher data through `Codable`).
@Suite("JSONValue")
struct JSONValueTests {
    // MARK: - Parsing

    @Test("parse decodes every scalar kind correctly, including distinguishing bool from int")
    func parseDecodesEveryScalarKind() throws {
        let json = """
        {"a_string":"hello","an_int":42,"a_double":3.5,"a_bool":true,"a_null":null}
        """
        let value = try JSONValue.parse(string: json)
        guard case .object(let members) = value else {
            Issue.record("expected an object")
            return
        }
        let byKey = Dictionary(members.map { ($0.key, $0.value) }, uniquingKeysWith: { _, last in last })
        #expect(byKey["a_string"] == .string("hello"))
        #expect(byKey["an_int"] == .int(42))
        #expect(byKey["a_double"] == .double(3.5))
        #expect(byKey["a_bool"] == .bool(true))
        #expect(byKey["a_null"] == .null)
    }

    @Test("parse keeps snake_case keys as-is, without any camelCase conversion")
    func parsePreservesSnakeCaseKeys() throws {
        let json = "{\"source_seg_id\":\"seg_00001\"}"
        let value = try JSONValue.parse(string: json)
        guard case .object(let members) = value else {
            Issue.record("expected an object")
            return
        }
        #expect(members.map(\.key) == ["source_seg_id"])
    }

    @Test("parse decodes nested arrays and objects")
    func parseDecodesNestedStructures() throws {
        let json = "{\"items\":[{\"id\":1},{\"id\":2}]}"
        let value = try JSONValue.parse(string: json)
        guard case .object(let members) = value, let itemsValue = members.first(where: { $0.key == "items" })?.value,
              case .array(let items) = itemsValue else {
            Issue.record("expected items array")
            return
        }
        #expect(items.count == 2)
        guard case .object(let first) = items[0] else {
            Issue.record("expected object element")
            return
        }
        #expect(first.first?.key == "id")
        #expect(first.first?.value == .int(1))
    }

    @Test("parse throws for invalid JSON text")
    func parseThrowsForInvalidJSON() {
        #expect(throws: (any Error).self) {
            _ = try JSONValue.parse(string: "{not valid json")
        }
    }

    // MARK: - Serialization

    @Test("serialize(pretty: false) preserves object member order exactly as constructed")
    func serializeCompactPreservesOrder() {
        let value = JSONValue.object([
            .init(key: "b", value: .string("2")),
            .init(key: "a", value: .string("1"))
        ])
        #expect(value.serialize(pretty: false) == "{\"b\":\"2\",\"a\":\"1\"}")
    }

    @Test("serialize(pretty: true) is human-readable and still preserves member order")
    func serializePrettyPreservesOrder() {
        let value = JSONValue.object([
            .init(key: "b", value: .int(2)),
            .init(key: "a", value: .int(1))
        ])
        let rendered = value.serialize(pretty: true)
        #expect(rendered.contains("\"b\": 2"))
        #expect(rendered.contains("\"a\": 1"))
        let bIndex = rendered.range(of: "\"b\"")!.lowerBound
        let aIndex = rendered.range(of: "\"a\"")!.lowerBound
        #expect(bIndex < aIndex)
    }

    @Test("serialize escapes control characters and quotes correctly")
    func serializeEscapesSpecialCharacters() {
        let value = JSONValue.string("line1\nline2\t\"quoted\"")
        let rendered = value.serialize(pretty: false)
        #expect(rendered == "\"line1\\nline2\\t\\\"quoted\\\"\"")
    }

    /// Sorts every `.object`'s members by key, recursively -- `JSONValue.parse(_:)` itself does not
    /// preserve source member order (this type's own doc comment: parsing goes through
    /// `JSONSerialization`'s unordered `[String: Any]`), so a round-trip comparison must normalize
    /// order before comparing rather than asserting exact `Member` array equality.
    private func normalizedByKey(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let members):
            let sorted = members
                .map { JSONValue.Member(key: $0.key, value: normalizedByKey($0.value)) }
                .sorted { $0.key < $1.key }
            return .object(sorted)
        case .array(let items):
            return .array(items.map(normalizedByKey))
        case .string, .int, .double, .bool, .null:
            return value
        }
    }

    @Test("round trip: parse then serialize then parse again produces the same logical value")
    func parseSerializeRoundTrip() throws {
        let original = "{\"source_seg_id\":\"seg_00001\",\"count\":3,\"ok\":true,\"note\":null,\"items\":[\"a\",\"b\"]}"
        let value = try JSONValue.parse(string: original)
        let serialized = value.serialize(pretty: false)
        let reparsed = try JSONValue.parse(string: serialized)
        #expect(normalizedByKey(reparsed) == normalizedByKey(value))
    }

    @Test("empty object and array serialize compactly even in pretty mode")
    func emptyContainersSerializeCompactly() {
        #expect(JSONValue.object([]).serialize(pretty: true) == "{}")
        #expect(JSONValue.array([]).serialize(pretty: true) == "[]")
    }
}
