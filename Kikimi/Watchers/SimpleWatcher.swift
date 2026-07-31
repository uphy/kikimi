import Foundation

// MARK: - SimpleWatcherSpec

/// A `kind: simple` Watcher file's parsed contents -- the user-facing surface the simple form
/// (`Kikimi/Views/MeetingWorkspace/SimpleWatcherFormSheet.swift`) round-trips through
/// (`docs/design/34-simple-watchers.md` §3.1). `desugar(promptTemplate:)` is the only bridge to the
/// execution engine's `WatcherDefinition`; `WatcherRunner`/`WatcherLibrary`/`WatcherViewRenderer` never
/// see this type directly -- they only ever see the `WatcherDefinition` it desugars into.
struct SimpleWatcherSpec: Sendable, Equatable {
    var id: String
    var name: String
    /// `nil` falls back to `config.watchers.default_model`, same as `WatcherDefinition.model` (§3.1).
    var model: String?
    var trigger: WatcherTrigger
    var inputScope: WatcherInputScope
    /// The observation-viewpoint prompt: a `kind: simple` file's full body, trimmed. Never empty
    /// (`WatcherDefinitionParser`'s `simpleEmptyPrompt` rejects an empty body before this type is
    /// ever constructed, §2.1).
    var prompt: String
}

// MARK: - Desugaring (§4)

extension SimpleWatcherSpec {
    /// The single schema field every simple Watcher's LLM output is constrained to (§4's table).
    static let schemaFieldName = "markdown"

    /// The view template every simple Watcher renders with -- **triple** Mustache (`{{{markdown}}}`),
    /// not `{{markdown}}`: GRMustache.swift HTML-escapes `{{x}}`, which would corrupt Markdown
    /// containing `>` (blockquotes) or `&` (§4's table).
    static let viewTemplate = "{{{markdown}}}"

    /// `{{state}}`/`{{summary}}`/`{{recent_segments}}` are the only placeholders `WatcherPromptBuilder`
    /// recognizes (§6 of `docs/design/05-watcher-runner.md`); simple Watchers are `state_mode: snapshot`
    /// so `{{state}}` always expands to empty and is deliberately omitted here (§4.2).
    static let userPromptTemplate = """
    【直近のサマリ】
    {{summary}}

    【会話】
    {{recent_segments}}
    """

    /// The built-in default `# System` section template: a fixed preamble + output-rules footer
    /// wrapping a `{{viewpoint}}` placeholder (`docs/design/42-prompt-overrides.md` §2.1's
    /// `simple-watcher` row / §2.2). Forwards to `PromptSpec.spec(for: .simpleWatcher).defaultBody` --
    /// `Kikimi/Prompts/PromptSpec.swift` is this text's single source of truth (§2.2: "Moved from
    /// `SimpleWatcherSpec.systemPrompt(forViewpoint:)`"); this stays a Watchers-module-local alias so
    /// callers in this file (and `WatcherDefinitionParser`/`WatcherRunner`'s own default-parameter
    /// values) don't have to spell out the `Kikimi/Prompts/` type every time they need "no override
    /// active" behavior.
    static var defaultSystemPromptTemplate: String {
        PromptSpec.spec(for: .simpleWatcher).defaultBody
    }

    /// Builds the `# System` section body: `template` (the built-in default, or a
    /// `prompts/simple-watcher.md` override's active body) with its required `{{viewpoint}}`
    /// placeholder expanded to `viewpoint` via `PromptPlaceholder.expand`
    /// (`docs/design/42-prompt-overrides.md` §4.2). Never re-interpolated per run -- keeps the
    /// prompt-cache-friendly "System は実行間で完全固定" property (§4.1 of
    /// `docs/design/34-simple-watchers.md`). `template` is expected to already be resolved by the
    /// caller (session-start snapshot for `WatcherRunner`, current value for the Prep-tab/UI paths --
    /// see `docs/design/42-prompt-overrides.md` §4.3); this function itself does no resolution.
    static func systemPrompt(template: String, viewpoint: String) -> String {
        PromptPlaceholder.expand(template: template, replacements: [("{{viewpoint}}", viewpoint)])
    }

    /// Builds this spec's `WatcherDefinition` (§4's table): `state_mode: snapshot`, the single
    /// `markdown: string` schema field, the triple-Mustache view, no `initial_state`, and
    /// `simpleSpec: self` so the UI can route this row back to the simple form
    /// (`docs/design/34-simple-watchers.md` §6.3). This is the *only* place a `kind: simple` file's
    /// runtime behavior is decided -- `WatcherRunner` never special-cases `simpleSpec`.
    ///
    /// - Parameter promptTemplate: The `# System` section template to embed `prompt` into (see
    ///   `systemPrompt(template:viewpoint:)`). Callers pass the currently-resolved
    ///   `simple-watcher` prompt override body (or `Self.defaultSystemPromptTemplate` if none is
    ///   active) -- this function performs no resolution of its own
    ///   (`docs/design/42-prompt-overrides.md` §4.2/§4.3).
    func desugar(promptTemplate: String) -> WatcherDefinition {
        WatcherDefinition(
            id: id,
            name: name,
            model: model,
            trigger: trigger,
            stateMode: .snapshot,
            inputScope: inputScope,
            schema: WatcherSchema(fields: [
                .init(name: Self.schemaFieldName, type: .string, nullable: false)
            ]),
            view: Self.viewTemplate,
            initialState: nil,
            systemPrompt: Self.systemPrompt(template: promptTemplate, viewpoint: prompt),
            userPromptTemplate: Self.userPromptTemplate,
            simpleSpec: self
        )
    }
}

// MARK: - `fileText()` (§2, §3.1)

extension SimpleWatcherSpec {
    /// Renders this spec back into a `kind: simple` `.md` file's full text -- the simple form's save
    /// action writes this verbatim to `watchers/<id>.md` (§6.2). Built by hand-assembling lines rather
    /// than routing through Yams' emitter, so key order/quoting stays exactly what's written here
    /// across Yams versions (§3.1: "Yams の emit は使わない -- キー順・体裁を決定論的に保つ").
    func fileText() -> String {
        var lines = [
            "---",
            "kind: simple",
            "id: \(id)",
            "name: \(Self.doubleQuotedYAMLScalar(name))",
            "trigger: \(Self.plainScalar(forTrigger: trigger))",
            "input_scope: \(Self.plainScalar(forInputScope: inputScope))"
        ]
        if let model {
            lines.append("model: \(Self.doubleQuotedYAMLScalar(model))")
        }
        lines.append("---")
        lines.append("")
        lines.append(prompt)
        return lines.joined(separator: "\n")
    }
}

// MARK: - `desugaredFullText()` (§7)

extension SimpleWatcherSpec {
    /// Renders this spec's `desugar(promptTemplate:)` result as a **full-format** `.md` text --
    /// "詳細形式に変換…"'s output (§7). Pure text generation only; the round-trip check §7 requires
    /// before any caller persists this text (`WatcherDefinitionParser.parse` the result, compare
    /// against `desugar(promptTemplate:)` ignoring `simpleSpec`) is the caller's responsibility
    /// (`MeetingWorkspaceViewModel.convertSimpleWatcherToFull(id:)`), not this function's -- eject is a
    /// UI-triggered, one-shot action, not something every `desugar(promptTemplate:)` call needs to pay
    /// for.
    ///
    /// `name`/`model`/`view` are emitted as double-quoted scalars (same escaping helper `fileText()`
    /// uses); `id`/`trigger`/`state_mode`/`input_scope` as plain scalars (§7's emit-format bullets).
    /// `view`'s value (`{{{markdown}}}`) specifically *must* be double-quoted, not plain: a plain
    /// scalar starting with `{` parses as YAML flow-mapping syntax, so `WatcherDefinitionParser` would
    /// see `mapping["view"]?.string == nil` and throw `missingRequiredField("view")` (verified against
    /// `WatcherDefinition.swift`'s parse implementation, §7).
    ///
    /// - Parameter promptTemplate: Forwarded to `systemPrompt(template:viewpoint:)` -- see
    ///   `desugar(promptTemplate:)`'s doc comment. The caller of `convertSimpleWatcherToFull(id:)`
    ///   (`MeetingWorkspaceViewModel+Watchers.swift`) must pass the *same* value here as it passes to
    ///   the paired `desugar(promptTemplate:)` call its round-trip check compares against
    ///   (`docs/design/42-prompt-overrides.md` §4.3) -- a mismatched template would make that
    ///   comparison fail on an unrelated `systemPrompt` difference.
    func desugaredFullText(promptTemplate: String) -> String {
        var lines = [
            "---",
            "id: \(id)",
            "name: \(Self.doubleQuotedYAMLScalar(name))"
        ]
        if let model {
            lines.append("model: \(Self.doubleQuotedYAMLScalar(model))")
        }
        lines.append("trigger: \(Self.plainScalar(forTrigger: trigger))")
        lines.append("state_mode: snapshot")
        lines.append("input_scope: \(Self.plainScalar(forInputScope: inputScope))")
        lines.append("schema:")
        lines.append("  \(Self.schemaFieldName): string")
        lines.append("view: \(Self.doubleQuotedYAMLScalar(Self.viewTemplate))")
        lines.append("---")
        lines.append("")
        lines.append("# System")
        lines.append("")
        lines.append(Self.systemPrompt(template: promptTemplate, viewpoint: prompt))
        lines.append("")
        lines.append("# User")
        lines.append("")
        lines.append(Self.userPromptTemplate)
        return lines.joined(separator: "\n")
    }
}

// MARK: - Frontmatter scalar rendering helpers

private extension SimpleWatcherSpec {
    /// `trigger`'s frontmatter text form -- the exact inverse of `WatcherDefinitionParser`'s
    /// `parseTrigger(_:)`. ASCII keywords/digits only, so this is always safe as a YAML plain scalar.
    static func plainScalar(forTrigger trigger: WatcherTrigger) -> String {
        switch trigger {
        case .onSummaryUpdate:
            return "on_summary_update"
        case .onSessionEnd:
            return "on_session_end"
        case .onManual:
            return "on_manual"
        case .onInterval(let seconds):
            return "on_interval:\(seconds)"
        }
    }

    /// `inputScope`'s frontmatter text form -- the exact inverse of `WatcherDefinitionParser`'s
    /// `parseInputScope(_:)`. `summaryAndRecent` always emits the explicit `:<n>` suffix (never the
    /// bare, default-implying `summary_and_recent` form) since every spec this type represents -- form
    /// draft or hand-edited file -- already carries a concrete count (`docs/design/34-simple-watchers.md`
    /// §2's own example: `input_scope: summary_and_recent:30`, count spelled out even though it's the
    /// default). ASCII keywords/digits only, so this is always safe as a YAML plain scalar.
    static func plainScalar(forInputScope inputScope: WatcherInputScope) -> String {
        inputScope.scalarValue
    }

    /// Renders `raw` as a YAML double-quoted scalar, escaping the three characters that would
    /// otherwise break it: `"` and `\` (both meaningful inside a double-quoted scalar), plus a literal
    /// newline (`\n`, re-escaped so a multi-line `name` -- however it got there, e.g. from outside the
    /// simple form -- can't break the double-quoted scalar's line folding, §3.1). No other control
    /// characters are expected in these fields (`name`/`model`/`view`), so no other escapes are needed.
    static func doubleQuotedYAMLScalar(_ raw: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(raw.count + 2)
        for character in raw {
            switch character {
            case "\"":
                escaped += "\\\""
            case "\\":
                escaped += "\\\\"
            case "\n":
                escaped += "\\n"
            default:
                escaped.append(character)
            }
        }
        return "\"\(escaped)\""
    }
}
