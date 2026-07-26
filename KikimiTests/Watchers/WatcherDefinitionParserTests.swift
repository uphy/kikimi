import Foundation
import Testing

@testable import Kikimi

/// Layer 1 coverage for `WatcherDefinitionParser` (`docs/design/05-watcher-runner.md` §4): frontmatter
/// delimiter handling, required-field/trigger/state_mode/input_scope parsing, `# System`/`# User`
/// section extraction, and the id/expectedId consistency check.
@Suite("WatcherDefinitionParser")
struct WatcherDefinitionParserTests {
    private func validDefinitionText(
        id: String = "pre-check",
        trigger: String = "on_summary_update",
        extraFrontmatter: String = "",
        schema: String = "question: string",
        systemBody: String = "システムプロンプト本文",
        userBody: String = "ユーザープロンプト本文 {{state}}"
    ) -> String {
        """
        ---
        id: \(id)
        name: 事前確認事項チェッカー
        trigger: \(trigger)
        state_mode: cumulative
        input_scope: summary_and_recent
        schema:
          \(schema)
        view: |
          {{question}}
        \(extraFrontmatter)---

        # System

        \(systemBody)

        # User

        \(userBody)
        """
    }

    // MARK: - Frontmatter delimiters

    @Test("a definition missing the opening \"---\" throws missingFrontmatterDelimiter")
    func missingOpeningDelimiterThrows() {
        let text = "id: pre-check\n---\n# System\ns\n# User\nu"
        #expect(throws: WatcherParseError.missingFrontmatterDelimiter) {
            _ = try WatcherDefinitionParser.parse(text: text, expectedId: "pre-check")
        }
    }

    @Test("a definition missing the closing \"---\" throws missingClosingFrontmatterDelimiter")
    func missingClosingDelimiterThrows() {
        let text = "---\nid: pre-check\n# System\ns\n# User\nu"
        #expect(throws: WatcherParseError.missingClosingFrontmatterDelimiter) {
            _ = try WatcherDefinitionParser.parse(text: text, expectedId: "pre-check")
        }
    }

    // MARK: - Required fields

    @Test("a definition missing a required frontmatter field throws missingRequiredField")
    func missingRequiredFieldThrows() {
        let text = """
        ---
        id: pre-check
        trigger: on_summary_update
        state_mode: cumulative
        input_scope: summary_and_recent
        schema:
          question: string
        view: |
          {{question}}
        ---

        # System
        s

        # User
        u
        """
        #expect(throws: WatcherParseError.missingRequiredField("name")) {
            _ = try WatcherDefinitionParser.parse(text: text, expectedId: "pre-check")
        }
    }

    @Test("a definition missing the schema field throws missingRequiredField(\"schema\")")
    func missingSchemaFieldThrows() {
        let text = """
        ---
        id: pre-check
        name: n
        trigger: on_manual
        state_mode: cumulative
        input_scope: summary
        view: |
          {{question}}
        ---

        # System
        s

        # User
        u
        """
        #expect(throws: WatcherParseError.missingRequiredField("schema")) {
            _ = try WatcherDefinitionParser.parse(text: text, expectedId: "pre-check")
        }
    }

    @Test("a definition missing the view field throws missingRequiredField(\"view\")")
    func missingViewFieldThrows() {
        let text = """
        ---
        id: pre-check
        name: n
        trigger: on_manual
        state_mode: cumulative
        input_scope: summary
        schema:
          question: string
        ---

        # System
        s

        # User
        u
        """
        #expect(throws: WatcherParseError.missingRequiredField("view")) {
            _ = try WatcherDefinitionParser.parse(text: text, expectedId: "pre-check")
        }
    }

    @Test("frontmatter that is not a YAML mapping throws frontmatterMustBeMapping")
    func nonMappingFrontmatterThrows() {
        let text = """
        ---
        - just
        - a
        - list
        ---

        # System
        s

        # User
        u
        """
        #expect(throws: WatcherParseError.frontmatterMustBeMapping) {
            _ = try WatcherDefinitionParser.parse(text: text, expectedId: "pre-check")
        }
    }

    @Test("a schema field that fails to parse throws invalidSchema")
    func invalidSchemaThrows() {
        let text = """
        ---
        id: pre-check
        name: n
        trigger: on_manual
        state_mode: cumulative
        input_scope: summary
        schema:
          question: not_a_real_type
        view: |
          {{question}}
        ---

        # System
        s

        # User
        u
        """
        do {
            _ = try WatcherDefinitionParser.parse(text: text, expectedId: "pre-check")
            Issue.record("expected parse to throw invalidSchema")
        } catch let error as WatcherParseError {
            guard case .invalidSchema = error else {
                Issue.record("expected invalidSchema, got \(error)")
                return
            }
        } catch {
            Issue.record("expected WatcherParseError, got \(error)")
        }
    }

    @Test("a fully valid definition parses into the expected WatcherDefinition")
    func validDefinitionParsesSuccessfully() throws {
        let definition = try WatcherDefinitionParser.parse(text: validDefinitionText(), expectedId: "pre-check")
        #expect(definition.id == "pre-check")
        #expect(definition.name == "事前確認事項チェッカー")
        #expect(definition.model == nil)
        #expect(definition.trigger == .onSummaryUpdate)
        #expect(definition.stateMode == .cumulative)
        #expect(definition.inputScope == .summaryAndRecent(count: 30))
        #expect(definition.schema.fields == [.init(name: "question", type: .string, nullable: false)])
        #expect(definition.systemPrompt == "システムプロンプト本文")
        #expect(definition.userPromptTemplate == "ユーザープロンプト本文 {{state}}")
    }

    @Test("model, when present, is parsed")
    func modelFieldIsParsedWhenPresent() throws {
        let text = validDefinitionText(extraFrontmatter: "model: claude-haiku-4-5-20251001\n")
        let definition = try WatcherDefinitionParser.parse(text: text, expectedId: "pre-check")
        #expect(definition.model == "claude-haiku-4-5-20251001")
    }

    // MARK: - kind (`docs/design/34-simple-watchers.md` §3.2)

    private func simpleDefinitionText(
        id: String = "pre-check",
        trigger: String = "on_summary_update",
        inputScope: String = "summary_and_recent:10",
        extraFrontmatter: String = "",
        prompt: String = "いま議論している論点を3つ以内で整理してください。"
    ) -> String {
        """
        ---
        kind: simple
        id: \(id)
        name: 論点整理
        trigger: \(trigger)
        input_scope: \(inputScope)
        \(extraFrontmatter)---

        \(prompt)
        """
    }

    @Test("a definition with no kind field parses via the full-definition path")
    func absentKindParsesAsFullDefinition() throws {
        let definition = try WatcherDefinitionParser.parse(text: validDefinitionText(), expectedId: "pre-check")
        #expect(definition.simpleSpec == nil)
        #expect(definition.stateMode == .cumulative)
    }

    @Test("kind: full parses via the full-definition path")
    func explicitFullKindParsesAsFullDefinition() throws {
        let text = validDefinitionText(extraFrontmatter: "kind: full\n")
        let definition = try WatcherDefinitionParser.parse(text: text, expectedId: "pre-check")
        #expect(definition.simpleSpec == nil)
        #expect(definition.stateMode == .cumulative)
    }

    @Test("kind: simple desugars into a snapshot WatcherDefinition carrying the originating spec")
    func simpleKindDesugarsIntoWatcherDefinition() throws {
        let definition = try WatcherDefinitionParser.parse(
            text: simpleDefinitionText(),
            expectedId: "pre-check"
        )
        #expect(definition.id == "pre-check")
        #expect(definition.name == "論点整理")
        #expect(definition.trigger == .onSummaryUpdate)
        #expect(definition.inputScope == .summaryAndRecent(count: 10))
        #expect(definition.stateMode == .snapshot)
        #expect(definition.schema.fields == [.init(name: "markdown", type: .string, nullable: false)])
        #expect(definition.view == "{{{markdown}}}")
        #expect(definition.initialState == nil)
        #expect(definition.systemPrompt.contains("いま議論している論点を3つ以内で整理してください。"))
        #expect(definition.userPromptTemplate.contains("{{summary}}"))
        #expect(definition.userPromptTemplate.contains("{{recent_segments}}"))
        #expect(!definition.userPromptTemplate.contains("{{state}}"))
        #expect(definition.simpleSpec?.id == "pre-check")
        #expect(definition.simpleSpec?.prompt == "いま議論している論点を3つ以内で整理してください。")
    }

    @Test("an unknown kind value throws unknownKind")
    func unknownKindThrows() {
        let text = validDefinitionText(extraFrontmatter: "kind: bogus\n")
        #expect(throws: WatcherParseError.unknownKind("bogus")) {
            _ = try WatcherDefinitionParser.parse(text: text, expectedId: "pre-check")
        }
    }

    @Test(
        "kind: simple with a schema/view/state_mode/initial_state field throws simpleUnsupportedField(field)",
        arguments: [
            ("schema", "schema:\n  question: string\n"),
            ("view", "view: |\n  {{question}}\n"),
            ("state_mode", "state_mode: cumulative\n"),
            ("initial_state", "initial_state:\n  question: hi\n")
        ]
    )
    func simpleKindWithUnsupportedFieldThrows(field: String, extraFrontmatter: String) {
        let text = simpleDefinitionText(extraFrontmatter: extraFrontmatter)
        #expect(throws: WatcherParseError.simpleUnsupportedField(field)) {
            _ = try WatcherDefinitionParser.parse(text: text, expectedId: "pre-check")
        }
    }

    @Test("kind: simple with an empty body throws simpleEmptyPrompt")
    func simpleKindWithEmptyPromptThrows() {
        let text = simpleDefinitionText(prompt: "   ")
        #expect(throws: WatcherParseError.simpleEmptyPrompt) {
            _ = try WatcherDefinitionParser.parse(text: text, expectedId: "pre-check")
        }
    }

    @Test("kind: simple whose declared id does not match expectedId throws idDoesNotMatchExpectedId")
    func simpleKindIdMismatchThrows() {
        #expect(throws: WatcherParseError.idDoesNotMatchExpectedId(declaredId: "pre-check", expectedId: "other-id")) {
            _ = try WatcherDefinitionParser.parse(text: self.simpleDefinitionText(id: "pre-check"), expectedId: "other-id")
        }
    }

    // MARK: - trigger (§2.1)

    @Test("parses each fixed trigger keyword")
    func parsesFixedTriggerKeywords() throws {
        for (raw, expected) in [
            ("on_summary_update", WatcherTrigger.onSummaryUpdate),
            ("on_session_end", WatcherTrigger.onSessionEnd),
            ("on_manual", WatcherTrigger.onManual)
        ] {
            let definition = try WatcherDefinitionParser.parse(text: validDefinitionText(trigger: raw), expectedId: "pre-check")
            #expect(definition.trigger == expected)
        }
    }

    @Test("parses on_interval:<seconds> at or above the 10-second minimum unchanged")
    func parsesOnIntervalAboveMinimum() throws {
        let definition = try WatcherDefinitionParser.parse(text: validDefinitionText(trigger: "on_interval:30"), expectedId: "pre-check")
        #expect(definition.trigger == .onInterval(seconds: 30))
    }

    @Test("clamps on_interval:<seconds> below the 10-second minimum up to 10")
    func clampsOnIntervalBelowMinimum() throws {
        let definition = try WatcherDefinitionParser.parse(text: validDefinitionText(trigger: "on_interval:3"), expectedId: "pre-check")
        #expect(definition.trigger == .onInterval(seconds: 10))
    }

    @Test("an unparseable on_interval seconds value throws invalidIntervalSeconds")
    func invalidIntervalSecondsThrows() {
        #expect(throws: WatcherParseError.invalidIntervalSeconds("on_interval:abc")) {
            _ = try WatcherDefinitionParser.parse(text: self.validDefinitionText(trigger: "on_interval:abc"), expectedId: "pre-check")
        }
    }

    @Test("an unknown trigger value throws invalidTrigger")
    func unknownTriggerThrows() {
        #expect(throws: WatcherParseError.invalidTrigger("on_something_else")) {
            _ = try WatcherDefinitionParser.parse(text: self.validDefinitionText(trigger: "on_something_else"), expectedId: "pre-check")
        }
    }

    // MARK: - state_mode / input_scope

    @Test("an unknown state_mode value throws unknownStateMode")
    func unknownStateModeThrows() {
        let text = """
        ---
        id: pre-check
        name: n
        trigger: on_manual
        state_mode: bogus
        input_scope: summary
        schema:
          question: string
        view: |
          {{question}}
        ---

        # System
        s

        # User
        u
        """
        #expect(throws: WatcherParseError.unknownStateMode("bogus")) {
            _ = try WatcherDefinitionParser.parse(text: text, expectedId: "pre-check")
        }
    }

    @Test("an unknown input_scope value throws unknownInputScope")
    func unknownInputScopeThrows() {
        let text = """
        ---
        id: pre-check
        name: n
        trigger: on_manual
        state_mode: cumulative
        input_scope: bogus
        schema:
          question: string
        view: |
          {{question}}
        ---

        # System
        s

        # User
        u
        """
        #expect(throws: WatcherParseError.unknownInputScope("bogus")) {
            _ = try WatcherDefinitionParser.parse(text: text, expectedId: "pre-check")
        }
    }

    @Test("input_scope: summary_and_recent without a count suffix resolves to the default count of 30")
    func summaryAndRecentWithoutSuffixResolvesToDefaultCount() throws {
        let definition = try WatcherDefinitionParser.parse(text: validDefinitionText(), expectedId: "pre-check")
        #expect(definition.inputScope == .summaryAndRecent(count: 30))
        #expect(WatcherInputScope.defaultRecentCount == 30)
    }

    @Test("input_scope: summary_and_recent:<n> parses the count")
    func summaryAndRecentWithCountSuffixParsesCount() throws {
        let text = """
        ---
        id: pre-check
        name: n
        trigger: on_manual
        state_mode: cumulative
        input_scope: summary_and_recent:12
        schema:
          question: string
        view: |
          {{question}}
        ---

        # System
        s

        # User
        u
        """
        let definition = try WatcherDefinitionParser.parse(text: text, expectedId: "pre-check")
        #expect(definition.inputScope == .summaryAndRecent(count: 12))
    }

    @Test("input_scope: summary_and_recent:<n> with a non-numeric n throws invalidRecentCount")
    func summaryAndRecentWithNonNumericCountThrows() {
        let text = """
        ---
        id: pre-check
        name: n
        trigger: on_manual
        state_mode: cumulative
        input_scope: summary_and_recent:abc
        schema:
          question: string
        view: |
          {{question}}
        ---

        # System
        s

        # User
        u
        """
        #expect(throws: WatcherParseError.invalidRecentCount("summary_and_recent:abc")) {
            _ = try WatcherDefinitionParser.parse(text: text, expectedId: "pre-check")
        }
    }

    @Test("input_scope: summary_and_recent:<n> clamps counts above 200 down to 200")
    func summaryAndRecentClampsCountAboveMaximum() throws {
        let text = """
        ---
        id: pre-check
        name: n
        trigger: on_manual
        state_mode: cumulative
        input_scope: summary_and_recent:500
        schema:
          question: string
        view: |
          {{question}}
        ---

        # System
        s

        # User
        u
        """
        let definition = try WatcherDefinitionParser.parse(text: text, expectedId: "pre-check")
        #expect(definition.inputScope == .summaryAndRecent(count: 200))
    }

    @Test("input_scope: full_refined parses to .fullRefined")
    func fullRefinedInputScopeParses() throws {
        let text = """
        ---
        id: pre-check
        name: n
        trigger: on_manual
        state_mode: cumulative
        input_scope: full_refined
        schema:
          question: string
        view: |
          {{question}}
        ---

        # System
        s

        # User
        u
        """
        let definition = try WatcherDefinitionParser.parse(text: text, expectedId: "pre-check")
        #expect(definition.inputScope == .fullRefined)
    }

    @Test("input_scope: summary parses to .summary")
    func summaryInputScopeParses() throws {
        let text = """
        ---
        id: pre-check
        name: n
        trigger: on_manual
        state_mode: cumulative
        input_scope: summary
        schema:
          question: string
        view: |
          {{question}}
        ---

        # System
        s

        # User
        u
        """
        let definition = try WatcherDefinitionParser.parse(text: text, expectedId: "pre-check")
        #expect(definition.inputScope == .summary)
    }

    @Test("input_scope: summary_and_recent:<n> clamps counts below 1 up to 1")
    func summaryAndRecentClampsCountBelowMinimum() throws {
        let text = """
        ---
        id: pre-check
        name: n
        trigger: on_manual
        state_mode: cumulative
        input_scope: summary_and_recent:0
        schema:
          question: string
        view: |
          {{question}}
        ---

        # System
        s

        # User
        u
        """
        let definition = try WatcherDefinitionParser.parse(text: text, expectedId: "pre-check")
        #expect(definition.inputScope == .summaryAndRecent(count: 1))
    }

    // MARK: - # System / # User sections (§4 step 3)

    @Test("extracts # System and # User section bodies, trimmed, ignoring any other H1 heading")
    func extractsSystemAndUserSections() throws {
        let text = """
        ---
        id: pre-check
        name: n
        trigger: on_manual
        state_mode: cumulative
        input_scope: summary
        schema:
          question: string
        view: |
          {{question}}
        ---

        # System

          システム本文（前後空白はtrimされる）

        # Unrelated Heading

        この内容は無視される

        # User

        ユーザー本文
        """
        let definition = try WatcherDefinitionParser.parse(text: text, expectedId: "pre-check")
        #expect(definition.systemPrompt == "システム本文（前後空白はtrimされる）")
        #expect(definition.userPromptTemplate == "ユーザー本文")
    }

    @Test("a definition missing the # System section throws missingSystemSection")
    func missingSystemSectionThrows() {
        let text = """
        ---
        id: pre-check
        name: n
        trigger: on_manual
        state_mode: cumulative
        input_scope: summary
        schema:
          question: string
        view: |
          {{question}}
        ---

        # User
        u
        """
        #expect(throws: WatcherParseError.missingSystemSection) {
            _ = try WatcherDefinitionParser.parse(text: text, expectedId: "pre-check")
        }
    }

    @Test("a definition missing the # User section throws missingUserSection")
    func missingUserSectionThrows() {
        let text = """
        ---
        id: pre-check
        name: n
        trigger: on_manual
        state_mode: cumulative
        input_scope: summary
        schema:
          question: string
        view: |
          {{question}}
        ---

        # System
        s
        """
        #expect(throws: WatcherParseError.missingUserSection) {
            _ = try WatcherDefinitionParser.parse(text: text, expectedId: "pre-check")
        }
    }

    // MARK: - id / expectedId consistency (§4 step 4)

    @Test("a definition whose declared id does not match expectedId throws idDoesNotMatchExpectedId")
    func idMismatchThrows() {
        #expect(throws: WatcherParseError.idDoesNotMatchExpectedId(declaredId: "pre-check", expectedId: "other-id")) {
            _ = try WatcherDefinitionParser.parse(text: self.validDefinitionText(id: "pre-check"), expectedId: "other-id")
        }
    }

    // MARK: - initial_state (§4 step 2)

    @Test("initial_state is parsed, schema-validated, and canonicalized")
    func initialStateIsParsedAndCanonicalized() throws {
        let text = """
        ---
        id: pre-check
        name: n
        trigger: on_manual
        state_mode: cumulative
        input_scope: summary
        schema:
          status: string
          question: string
        initial_state: |
          {"question": "q", "status": "open"}
        view: |
          {{question}}
        ---

        # System
        s

        # User
        u
        """
        let definition = try WatcherDefinitionParser.parse(text: text, expectedId: "pre-check")
        guard case .object(let members) = definition.initialState else {
            Issue.record("expected an object initialState")
            return
        }
        // Canonicalized into schema declaration order (status, question), not the source order.
        #expect(members.map(\.key) == ["status", "question"])
    }

    @Test("initial_state that fails schema validation throws initialStateFailsSchemaValidation")
    func initialStateFailingValidationThrows() {
        let text = """
        ---
        id: pre-check
        name: n
        trigger: on_manual
        state_mode: cumulative
        input_scope: summary
        schema:
          question: string
        initial_state: |
          {"question": null}
        view: |
          {{question}}
        ---

        # System
        s

        # User
        u
        """
        #expect(throws: (any Error).self) {
            _ = try WatcherDefinitionParser.parse(text: text, expectedId: "pre-check")
        }
    }

    @Test("a definition with no initial_state parses with a nil initialState")
    func noInitialStateParsesAsNil() throws {
        let definition = try WatcherDefinitionParser.parse(text: validDefinitionText(), expectedId: "pre-check")
        #expect(definition.initialState == nil)
    }
}
