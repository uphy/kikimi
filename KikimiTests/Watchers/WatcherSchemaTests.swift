import Foundation
import Testing
import Yams

@testable import Kikimi

/// Layer 1 coverage for `WatcherSchema` (`docs/design/05-watcher-runner.md` §2.3/§2.4): type-notation
/// parsing, JSON Schema generation, `validate(_:)`, and `canonicalize(_:)`.
@Suite("WatcherSchema")
struct WatcherSchemaTests {
    private func parseSchema(_ yaml: String) throws -> WatcherSchema {
        let node = try Yams.compose(yaml: yaml)!
        return try WatcherSchema.parse(node: node)
    }

    // MARK: - Parsing

    @Test("parses scalar field types, including nullable variants")
    func parsesScalarFieldTypes() throws {
        let schema = try parseSchema("""
        name: string
        age: int
        score: float
        active: bool
        note: string?
        """)
        #expect(schema.fields == [
            .init(name: "name", type: .string, nullable: false),
            .init(name: "age", type: .int, nullable: false),
            .init(name: "score", type: .float, nullable: false),
            .init(name: "active", type: .bool, nullable: false),
            .init(name: "note", type: .string, nullable: true)
        ])
    }

    @Test("parses enum declarations, including nullable")
    func parsesEnumDeclarations() throws {
        let schema = try parseSchema("""
        status: enum[open, partial, answered]
        priority: enum[low, high]?
        """)
        #expect(schema.fields[0].type == .enumeration(["open", "partial", "answered"]))
        #expect(schema.fields[0].nullable == false)
        #expect(schema.fields[1].type == .enumeration(["low", "high"]))
        #expect(schema.fields[1].nullable == true)
    }

    @Test("parses a nested mapping as an object field")
    func parsesNestedObjectField() throws {
        let schema = try parseSchema("""
        author:
          name: string
          age: int
        """)
        #expect(schema.fields.count == 1)
        #expect(schema.fields[0].name == "author")
        #expect(schema.fields[0].type == .object([
            .init(name: "name", type: .string, nullable: false),
            .init(name: "age", type: .int, nullable: false)
        ]))
    }

    @Test("parses a single-element sequence as an array field")
    func parsesArrayField() throws {
        let schema = try parseSchema("""
        items:
          - id: int
            question: string
        """)
        #expect(schema.fields.count == 1)
        #expect(schema.fields[0].type == .array(.object([
            .init(name: "id", type: .int, nullable: false),
            .init(name: "question", type: .string, nullable: false)
        ])))
    }

    @Test("an array declaration with more than one element throws")
    func arrayWithMultipleElementsThrows() {
        #expect(throws: (any Error).self) {
            _ = try self.parseSchema("""
            items:
              - id: int
              - question: string
            """)
        }
    }

    @Test("an unknown scalar type throws")
    func unknownScalarTypeThrows() {
        #expect(throws: (any Error).self) {
            _ = try self.parseSchema("weird: mystery")
        }
    }

    @Test("an empty enum declaration throws")
    func emptyEnumDeclarationThrows() {
        #expect(throws: (any Error).self) {
            _ = try self.parseSchema("status: enum[]")
        }
    }

    @Test("a non-mapping top-level schema throws")
    func nonMappingTopLevelThrows() {
        #expect(throws: (any Error).self) {
            let node = try Yams.compose(yaml: "- a\n- b")!
            _ = try WatcherSchema.parse(node: node)
        }
    }

    // MARK: - JSON Schema generation (§2.4)

    @Test("jsonSchemaString renders scalar/enum/array/object types with additionalProperties: false and all-required")
    func jsonSchemaStringRendersExpectedShape() throws {
        let schema = try parseSchema("""
        question: string
        status: enum[open, answered]
        answer: string?
        items:
          - id: int
        """)
        let json = schema.jsonSchemaString()
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        #expect(parsed["type"] as? String == "object")
        #expect(parsed["additionalProperties"] as? Bool == false)
        #expect(parsed["required"] as? [String] == ["question", "status", "answer", "items"])

        let properties = parsed["properties"] as! [String: Any]
        #expect((properties["question"] as! [String: Any])["type"] as? String == "string")
        let statusProperty = properties["status"] as! [String: Any]
        #expect(statusProperty["enum"] as? [String] == ["open", "answered"])
        let answerProperty = properties["answer"] as! [String: Any]
        #expect(answerProperty["type"] as? [String] == ["string", "null"])
        let itemsProperty = properties["items"] as! [String: Any]
        #expect(itemsProperty["type"] as? String == "array")
    }

    @Test("jsonSchemaString's properties/required order follows field declaration order")
    func jsonSchemaStringPreservesDeclarationOrder() throws {
        let schema = try parseSchema("""
        zeta: string
        alpha: string
        middle: string
        """)
        let json = schema.jsonSchemaString()
        let zetaIndex = json.range(of: "\"zeta\"")!.lowerBound
        let alphaIndex = json.range(of: "\"alpha\"")!.lowerBound
        #expect(zetaIndex < alphaIndex)
    }

    // MARK: - validate (§2.4)

    @Test("validate passes for a fully conformant value")
    func validatePassesForConformantValue() throws {
        let schema = try parseSchema("""
        question: string
        status: enum[open, answered]
        answer: string?
        """)
        let value = try JSONValue.parse(string: "{\"question\":\"q\",\"status\":\"open\",\"answer\":null}")
        #expect(schema.validate(value).isEmpty)
    }

    @Test("validate reports a missing required field")
    func validateReportsMissingField() throws {
        let schema = try parseSchema("question: string\nstatus: enum[open, answered]")
        let value = try JSONValue.parse(string: "{\"question\":\"q\"}")
        #expect(!schema.validate(value).isEmpty)
    }

    @Test("validate rejects null for a non-nullable field")
    func validateRejectsNullForNonNullableField() throws {
        let schema = try parseSchema("question: string")
        let value = try JSONValue.parse(string: "{\"question\":null}")
        #expect(!schema.validate(value).isEmpty)
    }

    @Test("validate rejects an enum value outside the declared set")
    func validateRejectsUnknownEnumValue() throws {
        let schema = try parseSchema("status: enum[open, answered]")
        let value = try JSONValue.parse(string: "{\"status\":\"unknown\"}")
        #expect(!schema.validate(value).isEmpty)
    }

    @Test("validate accepts a whole-number double for an int field, and an int for a float field")
    func validateAcceptsCrossNumericTypes() throws {
        let schema = try parseSchema("count: int\nratio: float")
        let value = try JSONValue.parse(string: "{\"count\":3.0,\"ratio\":2}")
        #expect(schema.validate(value).isEmpty)
    }

    @Test("validate rejects a fractional double for an int field")
    func validateRejectsFractionalDoubleForIntField() throws {
        let schema = try parseSchema("count: int")
        let value = try JSONValue.parse(string: "{\"count\":3.5}")
        #expect(!schema.validate(value).isEmpty)
    }

    @Test("validate recurses into array elements")
    func validateRecursesIntoArrayElements() throws {
        let schema = try parseSchema("""
        items:
          - id: int
            question: string
        """)
        let value = try JSONValue.parse(string: "{\"items\":[{\"id\":1,\"question\":\"q\"},{\"id\":\"not-an-int\",\"question\":\"q2\"}]}")
        #expect(!schema.validate(value).isEmpty)
    }

    // MARK: - canonicalize (§2.2)

    @Test("canonicalize reorders top-level members into schema declaration order")
    func canonicalizeReordersTopLevel() throws {
        let schema = try parseSchema("zeta: string\nalpha: string")
        let value = try JSONValue.parse(string: "{\"alpha\":\"a\",\"zeta\":\"z\"}")
        let canonical = schema.canonicalize(value)
        guard case .object(let members) = canonical else {
            Issue.record("expected object")
            return
        }
        #expect(members.map(\.key) == ["zeta", "alpha"])
    }

    @Test("canonicalize reorders nested object fields and array-of-object elements recursively")
    func canonicalizeReordersNestedStructures() throws {
        let schema = try parseSchema("""
        items:
          - id: int
            question: string
        """)
        let value = try JSONValue.parse(string: "{\"items\":[{\"question\":\"q\",\"id\":1}]}")
        let canonical = schema.canonicalize(value)
        guard case .object(let topMembers) = canonical,
              case .array(let items) = topMembers[0].value,
              case .object(let itemMembers) = items[0] else {
            Issue.record("expected nested object/array shape")
            return
        }
        #expect(itemMembers.map(\.key) == ["id", "question"])
    }

    @Test("canonicalize drops a field the value has that the schema does not declare")
    func canonicalizeDropsUndeclaredFields() throws {
        let schema = try parseSchema("alpha: string")
        let value = JSONValue.object([.init(key: "alpha", value: .string("a")), .init(key: "extra", value: .string("x"))])
        let canonical = schema.canonicalize(value)
        guard case .object(let members) = canonical else {
            Issue.record("expected object")
            return
        }
        #expect(members.map(\.key) == ["alpha"])
    }
}
