import Foundation
import Testing

@testable import Kikimi

/// Layer 1 coverage for `SimpleWatcherSpec` (`docs/design/34-simple-watchers.md` §3.1, §4, §7):
/// `desugar()`'s fixed mapping into a snapshot `WatcherDefinition`, `fileText()`'s escaping and
/// round-trip through `WatcherDefinitionParser.parse` (the `kind: simple` path), and
/// `desugaredFullText()`'s round-trip into an equivalent (`simpleSpec`-less) `WatcherDefinition`,
/// including the known `"# "`-prefixed-line mismatch case §7/§8.2 document.
@Suite("SimpleWatcherSpec")
struct SimpleWatcherSpecTests {
    /// The built-in default `# System` template, used throughout this suite wherever a test isn't
    /// specifically exercising a non-default `promptTemplate` (`docs/design/42-prompt-overrides.md`
    /// §4.2's `desugar(promptTemplate:)`/`desugaredFullText(promptTemplate:)` signatures).
    private let defaultTemplate = SimpleWatcherSpec.defaultSystemPromptTemplate

    private func spec(
        id: String = "simple-3f2a9c",
        name: String = "論点整理",
        model: String? = nil,
        trigger: WatcherTrigger = .onSummaryUpdate,
        inputScope: WatcherInputScope = .summaryAndRecent(count: 30),
        prompt: String = "いま議論している論点を3つ以内で整理してください。"
    ) -> SimpleWatcherSpec {
        SimpleWatcherSpec(id: id, name: name, model: model, trigger: trigger, inputScope: inputScope, prompt: prompt)
    }

    /// Compares two `WatcherDefinition`s the way `MeetingWorkspaceViewModel.convertSimpleWatcherToFull(id:)`
    /// does (§7): everything except `simpleSpec`, which a freshly-`WatcherDefinitionParser.parse`d
    /// full-format text can never carry (it declares no `kind: simple`).
    private func equalIgnoringSimpleSpec(_ lhs: WatcherDefinition, _ rhs: WatcherDefinition) -> Bool {
        var a = lhs
        a.simpleSpec = nil
        var b = rhs
        b.simpleSpec = nil
        return a == b
    }

    // MARK: - desugar() (§4)

    @Test("desugar() maps to a snapshot WatcherDefinition with the fixed markdown schema/view and no initial_state")
    func desugarProducesFixedSchemaAndView() {
        let definition = spec().desugar(promptTemplate: defaultTemplate)

        #expect(definition.id == "simple-3f2a9c")
        #expect(definition.name == "論点整理")
        #expect(definition.model == nil)
        #expect(definition.trigger == .onSummaryUpdate)
        #expect(definition.inputScope == .summaryAndRecent(count: 30))
        #expect(definition.stateMode == .snapshot)
        #expect(definition.schema.fields == [.init(name: "markdown", type: .string, nullable: false)])
        #expect(definition.view == "{{{markdown}}}")
        #expect(definition.initialState == nil)
    }

    @Test("desugar()'s systemPrompt embeds the observation prompt inside the fixed preamble/output-rules")
    func desugarSystemPromptEmbedsViewpoint() {
        let definition = spec(prompt: "いま議論している論点を3つ以内で整理してください。").desugar(promptTemplate: defaultTemplate)

        #expect(definition.systemPrompt.hasPrefix("あなたは会議のリアルタイム書き起こしを観察するアシスタントです。"))
        #expect(definition.systemPrompt.contains("【観点】\nいま議論している論点を3つ以内で整理してください。"))
        #expect(definition.systemPrompt.contains("markdown フィールドに結果の Markdown 本文を入れて返す"))
    }

    @Test("desugar()'s userPromptTemplate has summary/recent_segments but never state")
    func desugarUserPromptTemplateOmitsState() {
        let definition = spec().desugar(promptTemplate: defaultTemplate)

        #expect(definition.userPromptTemplate.contains("{{summary}}"))
        #expect(definition.userPromptTemplate.contains("{{recent_segments}}"))
        #expect(!definition.userPromptTemplate.contains("{{state}}"))
    }

    @Test("desugar() carries the spec itself as simpleSpec")
    func desugarCarriesSimpleSpec() {
        let originatingSpec = spec()
        let definition = originatingSpec.desugar(promptTemplate: defaultTemplate)

        #expect(definition.simpleSpec == originatingSpec)
    }

    // MARK: - fileText() round-trip (§3.1, §11.1)

    @Test("fileText() round-trips a name with a double quote, backslash, newline, and Japanese characters through WatcherDefinitionParser.parse")
    func fileTextRoundTripsEscapedName() throws {
        let originatingSpec = spec(
            id: "simple-abc123",
            name: "会議メモ \"重要\" \\注意\n(改行あり) 日本語名",
            model: nil,
            trigger: .onInterval(seconds: 45),
            inputScope: .summaryAndRecent(count: 15),
            prompt: "議事の脱線を検出してください。"
        )

        let text = originatingSpec.fileText()
        let parsed = try WatcherDefinitionParser.parse(text: text, expectedId: originatingSpec.id)

        #expect(parsed.simpleSpec == originatingSpec)
    }

    @Test("fileText() round-trips an escaped model value and omits the model line entirely when nil")
    func fileTextRoundTripsModel() throws {
        let withModel = spec(id: "simple-model1", model: "claude-\"custom\"\\model")
        let parsedWithModel = try WatcherDefinitionParser.parse(text: withModel.fileText(), expectedId: withModel.id)
        #expect(parsedWithModel.model == "claude-\"custom\"\\model")
        #expect(parsedWithModel.simpleSpec?.model == "claude-\"custom\"\\model")

        let withoutModel = spec(id: "simple-model2", model: nil)
        let text = withoutModel.fileText()
        #expect(!text.contains("model:"))
        let parsedWithoutModel = try WatcherDefinitionParser.parse(text: text, expectedId: withoutModel.id)
        #expect(parsedWithoutModel.model == nil)
    }

    @Test("fileText() writes the fixed kind/id/trigger/input_scope frontmatter lines and the prompt as the body")
    func fileTextStructure() {
        let text = spec(
            id: "simple-3f2a9c",
            trigger: .onSummaryUpdate,
            inputScope: .summaryAndRecent(count: 30),
            prompt: "いま議論している論点を3つ以内で整理してください。"
        ).fileText()

        #expect(text.hasPrefix("---\nkind: simple\nid: simple-3f2a9c\n"))
        #expect(text.contains("trigger: on_summary_update\n"))
        // §2's own example spells out the count explicitly even though it's the default.
        #expect(text.contains("input_scope: summary_and_recent:30\n"))
        #expect(text.hasSuffix("---\n\nいま議論している論点を3つ以内で整理してください。"))
    }

    @Test("fileText() round-trips every trigger kind through WatcherDefinitionParser.parse")
    func fileTextRoundTripsEveryTriggerKind() throws {
        for trigger: WatcherTrigger in [.onSummaryUpdate, .onSessionEnd, .onManual, .onInterval(seconds: 20)] {
            let originatingSpec = spec(id: "simple-trigger", trigger: trigger)
            let parsed = try WatcherDefinitionParser.parse(text: originatingSpec.fileText(), expectedId: originatingSpec.id)
            #expect(parsed.trigger == trigger)
        }
    }

    @Test("fileText() round-trips every input_scope kind through WatcherDefinitionParser.parse")
    func fileTextRoundTripsEveryInputScopeKind() throws {
        for inputScope: WatcherInputScope in [.summary, .summaryAndRecent(count: 12), .fullRefined] {
            let originatingSpec = spec(id: "simple-scope", inputScope: inputScope)
            let parsed = try WatcherDefinitionParser.parse(text: originatingSpec.fileText(), expectedId: originatingSpec.id)
            #expect(parsed.inputScope == inputScope)
        }
    }

    // MARK: - desugaredFullText() round-trip (§7, §11.1)

    @Test("desugaredFullText() round-trips through WatcherDefinitionParser.parse into a WatcherDefinition matching desugar() (ignoring simpleSpec)")
    func desugaredFullTextRoundTripsForOrdinaryPrompt() throws {
        let originatingSpec = spec(
            id: "simple-eject1",
            name: "脱線チェック",
            model: "claude-haiku-4-5-20251001",
            trigger: .onInterval(seconds: 90),
            inputScope: .fullRefined,
            prompt: "会議が脱線していないか確認してください。"
        )

        let fullText = originatingSpec.desugaredFullText(promptTemplate: defaultTemplate)
        let parsed = try WatcherDefinitionParser.parse(text: fullText, expectedId: originatingSpec.id)

        #expect(equalIgnoringSimpleSpec(parsed, originatingSpec.desugar(promptTemplate: defaultTemplate)))
        // Full-format text declares no `kind: simple`, so it parses via the full-definition path.
        #expect(parsed.simpleSpec == nil)
    }

    @Test("desugaredFullText()'s view is a double-quoted scalar that parses back to the triple-mustache template verbatim")
    func desugaredFullTextViewSurvivesDoubleQuoting() throws {
        let originatingSpec = spec(id: "simple-eject2")
        let parsed = try WatcherDefinitionParser.parse(text: originatingSpec.desugaredFullText(promptTemplate: defaultTemplate), expectedId: originatingSpec.id)

        #expect(parsed.view == "{{{markdown}}}")
    }

    @Test("desugaredFullText() mismatches desugar() when the prompt contains a \"# \"-prefixed line (the known convertSimpleWatcherToFull roundTripMismatch trigger)")
    func desugaredFullTextMismatchesForHashPrefixedLine() throws {
        let originatingSpec = spec(
            id: "simple-eject3",
            prompt: "見出し\n# 重要な論点\nここも見てほしい内容です。"
        )

        let fullText = originatingSpec.desugaredFullText(promptTemplate: defaultTemplate)
        // Parsing itself must still succeed (this is a silent content mismatch, not a parse failure --
        // §8.2's rationale for why the injection risk is a round-trip check, not a rejected character).
        let parsed = try WatcherDefinitionParser.parse(text: fullText, expectedId: originatingSpec.id)

        #expect(!equalIgnoringSimpleSpec(parsed, originatingSpec.desugar(promptTemplate: defaultTemplate)))
        #expect(parsed.systemPrompt != originatingSpec.desugar(promptTemplate: defaultTemplate).systemPrompt)
    }

    @Test("desugaredFullText() omits the model line when model is nil and includes it (double-quoted) when present")
    func desugaredFullTextModelLine() {
        let withModel = spec(id: "simple-eject4", model: "claude-haiku-4-5-20251001").desugaredFullText(promptTemplate: defaultTemplate)
        #expect(withModel.contains("model: \"claude-haiku-4-5-20251001\"\n"))

        let withoutModel = spec(id: "simple-eject5", model: nil).desugaredFullText(promptTemplate: defaultTemplate)
        #expect(!withoutModel.contains("model:"))
    }

    @Test("desugaredFullText() emits the fixed 2-line markdown schema and state_mode: snapshot")
    func desugaredFullTextFixedSchemaAndStateMode() {
        let text = spec(id: "simple-eject6").desugaredFullText(promptTemplate: defaultTemplate)

        #expect(text.contains("state_mode: snapshot\n"))
        #expect(text.contains("schema:\n  markdown: string\n"))
    }

    // MARK: - Non-default promptTemplate (`docs/design/42-prompt-overrides.md` §4.2/§4.3)

    /// A deliberately non-default template with distinctive fixed text around `{{viewpoint}}`, so
    /// assertions below can tell "the override's own wording" apart from `defaultTemplate`'s.
    private let overrideTemplate = """
    CUSTOM PREAMBLE
    {{viewpoint}}
    CUSTOM FOOTER
    """

    @Test("systemPrompt(template:viewpoint:) expands {{viewpoint}} into the given template, not the built-in default")
    func systemPromptExpandsIntoGivenTemplate() {
        let result = SimpleWatcherSpec.systemPrompt(template: overrideTemplate, viewpoint: "論点を整理して")
        #expect(result == "CUSTOM PREAMBLE\n論点を整理して\nCUSTOM FOOTER")
        #expect(!result.contains("あなたは会議のリアルタイム書き起こしを観察するアシスタントです。"))
    }

    @Test("desugar(promptTemplate:) embeds the observation prompt into a caller-supplied non-default template")
    func desugarUsesProvidedNonDefaultTemplate() {
        let definition = spec(prompt: "論点を整理して").desugar(promptTemplate: overrideTemplate)
        #expect(definition.systemPrompt == "CUSTOM PREAMBLE\n論点を整理して\nCUSTOM FOOTER")
    }

    @Test("desugaredFullText(promptTemplate:) round-trips through parse into a WatcherDefinition matching desugar(promptTemplate:) for a non-default template")
    func desugaredFullTextRoundTripsForNonDefaultTemplate() throws {
        let originatingSpec = spec(id: "simple-eject7", prompt: "論点を整理して")

        let fullText = originatingSpec.desugaredFullText(promptTemplate: overrideTemplate)
        let parsed = try WatcherDefinitionParser.parse(text: fullText, expectedId: originatingSpec.id)

        #expect(parsed.systemPrompt == "CUSTOM PREAMBLE\n論点を整理して\nCUSTOM FOOTER")
        #expect(equalIgnoringSimpleSpec(parsed, originatingSpec.desugar(promptTemplate: overrideTemplate)))
    }
}
