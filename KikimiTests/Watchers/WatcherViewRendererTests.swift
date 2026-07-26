import Foundation
import Testing

@testable import Kikimi

/// Layer 1 coverage for `WatcherViewRenderer` (`docs/design/05-watcher-runner.md` §8): derived enum
/// flags, render failure handling, and seg id linkification.
@Suite("WatcherViewRenderer")
struct WatcherViewRendererTests {
    private func obj(_ members: [(String, JSONValue)]) -> JSONValue {
        .object(members.map { JSONValue.Member(key: $0.0, value: $0.1) })
    }

    // MARK: - Derived flags (§8 step 2)

    @Test("injects is_<value> for every declared enum value, true only for the current value")
    func injectsDerivedFlagsForEnumField() {
        let schema = WatcherSchema(fields: [
            .init(name: "status", type: .enumeration(["open", "partial", "answered"]), nullable: false)
        ])
        let state = obj([("status", .string("partial"))])
        let template = "{{#is_open}}O{{/is_open}}{{#is_partial}}P{{/is_partial}}{{#is_answered}}A{{/is_answered}}"

        let rendered = WatcherViewRenderer.render(state: state, schema: schema, template: template)

        #expect(rendered == "P")
    }

    @Test("a null enum value yields all derived flags false")
    func nullEnumValueYieldsAllFlagsFalse() {
        let schema = WatcherSchema(fields: [
            .init(name: "status", type: .enumeration(["open", "answered"]), nullable: true)
        ])
        let state = obj([("status", .null)])
        let template = "{{#is_open}}O{{/is_open}}{{#is_answered}}A{{/is_answered}}none"

        let rendered = WatcherViewRenderer.render(state: state, schema: schema, template: template)

        #expect(rendered == "none")
    }

    @Test("a derived flag name colliding with a declared field name is not injected (declared field wins)")
    func collidingDerivedFlagIsNotInjected() {
        let schema = WatcherSchema(fields: [
            .init(name: "status", type: .enumeration(["open"]), nullable: false),
            .init(name: "is_open", type: .bool, nullable: false)
        ])
        let state = obj([("status", .string("open")), ("is_open", .bool(false))])
        let template = "{{#is_open}}shown{{/is_open}}{{^is_open}}hidden{{/is_open}}"

        let rendered = WatcherViewRenderer.render(state: state, schema: schema, template: template)

        // The declared `is_open: false` field wins over the derived flag that would have been `true`.
        #expect(rendered == "hidden")
    }

    @Test("triple-mustache {{{markdown}}} does not HTML-escape > or & (docs/design/34-simple-watchers.md §4)")
    func tripleMustacheDoesNotEscapeMarkdownCharacters() {
        let schema = WatcherSchema(fields: [.init(name: "markdown", type: .string, nullable: false)])
        let state = obj([("markdown", .string("> 引用と & 記号を含む Markdown"))])

        let rendered = WatcherViewRenderer.render(state: state, schema: schema, template: "{{{markdown}}}")

        #expect(rendered == "> 引用と & 記号を含む Markdown")
    }

    @Test("double-mustache {{markdown}} HTML-escapes > and & for contrast with the triple-mustache case above")
    func doubleMustacheEscapesMarkdownCharacters() {
        let schema = WatcherSchema(fields: [.init(name: "markdown", type: .string, nullable: false)])
        let state = obj([("markdown", .string("> 引用と & 記号を含む Markdown"))])

        let rendered = WatcherViewRenderer.render(state: state, schema: schema, template: "{{markdown}}")

        #expect(rendered == "&gt; 引用と &amp; 記号を含む Markdown")
    }

    @Test("renders nested object and array-of-object fields")
    func rendersNestedStructures() {
        let schema = WatcherSchema(fields: [
            .init(name: "items", type: .array(.object([
                .init(name: "question", type: .string, nullable: false)
            ])), nullable: false)
        ])
        let state = obj([("items", .array([
            obj([("question", .string("Q1"))]),
            obj([("question", .string("Q2"))])
        ]))])
        let template = "{{#items}}[{{question}}]{{/items}}"

        let rendered = WatcherViewRenderer.render(state: state, schema: schema, template: template)

        #expect(rendered == "[Q1][Q2]")
    }

    // MARK: - Render failure (§12)

    @Test("an unparseable Mustache template returns nil instead of crashing")
    func unparseableTemplateReturnsNil() {
        let schema = WatcherSchema(fields: [.init(name: "question", type: .string, nullable: false)])
        let state = obj([("question", .string("q"))])
        let rendered = WatcherViewRenderer.render(state: state, schema: schema, template: "{{#unclosed}}")

        #expect(rendered == nil)
    }

    // MARK: - seg id linkification (§8.1)

    @Test("linkifies a backticked seg id, removing the backticks")
    func linkifiesBacktickedSegId() {
        let schema = WatcherSchema(fields: [.init(name: "note", type: .string, nullable: false)])
        let state = obj([("note", .string("`seg_00042`"))])
        let rendered = WatcherViewRenderer.render(state: state, schema: schema, template: "{{note}}")

        #expect(rendered == "[seg_00042](kikimi-seg:seg_00042)")
    }

    @Test("linkifies a bare seg id")
    func linkifiesBareSegId() {
        let schema = WatcherSchema(fields: [.init(name: "note", type: .string, nullable: false)])
        let state = obj([("note", .string("見て seg_00042 です"))])
        let rendered = WatcherViewRenderer.render(state: state, schema: schema, template: "{{note}}")

        #expect(rendered == "見て [seg_00042](kikimi-seg:seg_00042) です")
    }

    @Test("does not double-linkify a seg id that is already inside a hand-authored link")
    func doesNotDoubleLinkifyExistingLink() {
        let schema = WatcherSchema(fields: [.init(name: "note", type: .string, nullable: false)])
        let state = obj([("note", .string("[詳細](kikimi-seg:seg_00042)"))])
        let rendered = WatcherViewRenderer.render(state: state, schema: schema, template: "{{note}}")

        #expect(rendered == "[詳細](kikimi-seg:seg_00042)")
    }

    @Test("linkifies multiple seg ids, both backticked and bare, in one render")
    func linkifiesMultipleSegIds() {
        let schema = WatcherSchema(fields: [.init(name: "note", type: .string, nullable: false)])
        let state = obj([("note", .string("最初は `seg_00001` 、次は seg_00002 です"))])
        let rendered = WatcherViewRenderer.render(state: state, schema: schema, template: "{{note}}")

        #expect(rendered == "最初は [seg_00001](kikimi-seg:seg_00001) 、次は [seg_00002](kikimi-seg:seg_00002) です")
    }
}
