import Foundation
import OSLog
import Yams

// MARK: - WatcherDefinition

/// A Watcher `.md` file's fully parsed contents (`docs/design/05-watcher-runner.md` §2.1, kikimi.md
/// 9 章 "Watcher ファイル形式"). Never cached by any consumer of this type -- `WatcherRunner` re-parses
/// the source text on every run, so a `.md` edit takes effect on the very next trigger (kikimi.md 9
/// 章 "Recording 中の .md 編集は次回発火から即反映").
struct WatcherDefinition: Sendable, Equatable {
    var id: String
    var name: String
    /// `nil` falls back to `config.watchers.default_model` (`WatcherRunner`'s job to resolve).
    var model: String?
    var trigger: WatcherTrigger
    var stateMode: WatcherStateMode
    var inputScope: WatcherInputScope
    var schema: WatcherSchema
    /// The Mustache view template, kept verbatim (rendering is `WatcherViewRenderer`'s job).
    var view: String
    /// Parsed + schema-validated + canonicalized `initial_state` frontmatter, if present.
    var initialState: JSONValue?
    /// The `# System` section body (fixed prompt, never re-interpolated -- §5.2).
    var systemPrompt: String
    /// The `# User` section body, containing `{{state}}`/`{{summary}}`/`{{recent_segments}}`
    /// placeholders `WatcherPromptBuilder` expands (§6).
    var userPromptTemplate: String
    /// Non-nil iff this definition was desugared from a `kind: simple` file (`docs/design/34-simple-watchers.md`
    /// §3.2). The UI uses it to route editing to the simple form; the runner never reads it.
    var simpleSpec: SimpleWatcherSpec?
}

// MARK: - WatcherTrigger

enum WatcherTrigger: Sendable, Equatable {
    case onSummaryUpdate
    case onSessionEnd
    case onManual
    /// Clamped to a minimum of `WatcherDefinitionParser.minimumIntervalSeconds` at parse time (§2.1).
    case onInterval(seconds: Int)
}

// MARK: - WatcherStateMode

enum WatcherStateMode: String, Sendable, Equatable {
    case cumulative
    case snapshot
    case appendOnly = "append_only"
}

// MARK: - WatcherInputScope

/// `docs/design/34-simple-watchers.md` §5: `summary_and_recent` carries a segment-count window
/// (`summary_and_recent:<n>`, defaulting to `defaultRecentCount` when unparameterized). Not
/// `RawRepresentable` -- the parameterized case can't round-trip through a single raw string.
enum WatcherInputScope: Sendable, Equatable {
    case summary
    case summaryAndRecent(count: Int)
    case fullRefined

    /// The window size an unparameterized `summary_and_recent` (no `:<n>` suffix) resolves to at
    /// parse time (§5). Kept here rather than on `WatcherRunner` so the parser doesn't depend on the
    /// runner's constants.
    static let defaultRecentCount = 30
}

// MARK: - WatcherParseError

/// Failure modes for `WatcherDefinitionParser.parse(text:expectedId:)` (§4, §12's "定義ファイルのパース
/// エラー" row). Every case carries enough context to surface directly in the UI's error badge
/// (kikimi.md 9 章 "`WatcherParseError` はケースごとに日本語で表示可能なメッセージを持つ").
enum WatcherParseError: LocalizedError, Equatable, Sendable {
    case missingFrontmatterDelimiter
    case missingClosingFrontmatterDelimiter
    case frontmatterMustBeMapping
    case missingRequiredField(String)
    case invalidTrigger(String)
    case invalidIntervalSeconds(String)
    case unknownStateMode(String)
    case unknownInputScope(String)
    case invalidSchema(String)
    case invalidInitialState(String)
    case initialStateFailsSchemaValidation([String])
    case missingSystemSection
    case missingUserSection
    case idDoesNotMatchExpectedId(declaredId: String, expectedId: String)
    /// `kind` frontmatter value other than absent/`full`/`simple` (`docs/design/34-simple-watchers.md` §3.2).
    case unknownKind(String)
    /// A `kind: simple` file declares `schema`/`view`/`state_mode`/`initial_state`, which are
    /// desugared automatically and must not be hand-authored (§2.1).
    case simpleUnsupportedField(String)
    /// A `kind: simple` file's body (the freeform prompt after frontmatter) is empty after trimming (§2.1).
    case simpleEmptyPrompt
    /// `summary_and_recent:<n>`'s `<n>` is not a parseable integer (§5).
    case invalidRecentCount(String)

    var errorDescription: String? {
        switch self {
        case .missingFrontmatterDelimiter:
            return "Watcher定義の先頭に \"---\" がありません。"
        case .missingClosingFrontmatterDelimiter:
            return "Watcher定義のfrontmatterを閉じる \"---\" がありません。"
        case .frontmatterMustBeMapping:
            return "Watcher定義のfrontmatterはYAMLマッピングである必要があります。"
        case .missingRequiredField(let field):
            return "Watcher定義に必須フィールド \"\(field)\" がありません。"
        case .invalidTrigger(let raw):
            return "不明な trigger 値です: \"\(raw)\""
        case .invalidIntervalSeconds(let raw):
            return "on_interval の秒数が不正です: \"\(raw)\""
        case .unknownStateMode(let raw):
            return "不明な state_mode 値です: \"\(raw)\""
        case .unknownInputScope(let raw):
            return "不明な input_scope 値です: \"\(raw)\""
        case .invalidSchema(let message):
            return "schema の解析に失敗しました: \(message)"
        case .invalidInitialState(let message):
            return "initial_state の解析に失敗しました: \(message)"
        case .initialStateFailsSchemaValidation(let errors):
            return "initial_state が schema に一致しません: \(errors.joined(separator: "; "))"
        case .missingSystemSection:
            return "\"# System\" セクションがありません。"
        case .missingUserSection:
            return "\"# User\" セクションがありません。"
        case .idDoesNotMatchExpectedId(let declaredId, let expectedId):
            return "定義の id \"\(declaredId)\" が期待される id \"\(expectedId)\" と一致しません。"
        case .unknownKind(let raw):
            return "不明な kind 値です: \"\(raw)\""
        case .simpleUnsupportedField(let field):
            return "kind: simple では \"\(field)\" は使用できません。詳細形式に変換してください。"
        case .simpleEmptyPrompt:
            return "プロンプト本文が空です。frontmatter の後に観点を書いてください。"
        case .invalidRecentCount(let raw):
            return "summary_and_recent の件数が不正です: \"\(raw)\""
        }
    }
}

// MARK: - WatcherDefinitionParser

/// Parses a Watcher `.md` file's full text into a `WatcherDefinition` (§4). Pure and stateless: no
/// file I/O (callers -- `WatcherLibrary`/`WatcherRunner` -- resolve the text first).
enum WatcherDefinitionParser {
    private static let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "WatcherDefinitionParser")

    /// Lower clamp for `on_interval:<seconds>` (§2.1, kikimi.md 9 章 "下限 10 秒にクランプ").
    static let minimumIntervalSeconds = 10

    /// - Parameters:
    ///   - text: The `.md` file's full contents.
    ///   - expectedId: The id this definition is expected to declare -- the lookup key
    ///     `WatcherLibrary.resolveDefinitionText(id:sessionHandle:)` resolved the text under (§4
    ///     step 4: "`id` がファイル名（拡張子除く）と不一致の場合はエラー"). Callers pass the id they looked the
    ///     text up by, not a filename, so this parser stays filesystem-agnostic.
    static func parse(text: String, expectedId: String) throws -> WatcherDefinition {
        let (frontmatterText, body) = try splitFrontmatter(text)
        let frontmatterNode: Node
        do {
            frontmatterNode = try Yams.compose(yaml: frontmatterText) ?? Node("")
        } catch {
            throw WatcherParseError.frontmatterMustBeMapping
        }
        guard case .mapping(let mapping) = frontmatterNode else {
            throw WatcherParseError.frontmatterMustBeMapping
        }

        // `docs/design/34-simple-watchers.md` §3.2: branch on `kind` right after the frontmatter is
        // parsed. Absent/`full` keeps the pre-existing full-definition parse path unchanged; `simple`
        // routes to the desugaring path; anything else is a parse error.
        switch mapping["kind"]?.string {
        case nil, "full":
            return try parseFullDefinition(mapping: mapping, body: body, expectedId: expectedId)
        case "simple":
            return try parseSimpleDefinition(mapping: mapping, body: body, expectedId: expectedId)
        case .some(let raw):
            throw WatcherParseError.unknownKind(raw)
        }
    }

    // MARK: - `kind` absent/`full` (§3.2)

    private static func parseFullDefinition(mapping: Node.Mapping, body: String, expectedId: String) throws -> WatcherDefinition {
        let id = try requiredString(mapping, key: "id")
        let name = try requiredString(mapping, key: "name")
        let model = mapping["model"]?.string
        let trigger = try parseTrigger(try requiredString(mapping, key: "trigger"))

        let stateModeRaw = try requiredString(mapping, key: "state_mode")
        guard let stateMode = WatcherStateMode(rawValue: stateModeRaw) else {
            throw WatcherParseError.unknownStateMode(stateModeRaw)
        }

        let inputScope = try parseInputScope(try requiredString(mapping, key: "input_scope"))

        guard let schemaNode = mapping["schema"] else {
            throw WatcherParseError.missingRequiredField("schema")
        }
        let schema: WatcherSchema
        do {
            schema = try WatcherSchema.parse(node: schemaNode)
        } catch {
            throw WatcherParseError.invalidSchema(String(describing: error))
        }

        guard let view = mapping["view"]?.string else {
            throw WatcherParseError.missingRequiredField("view")
        }

        let initialState = try parseInitialState(mapping: mapping, schema: schema)

        guard id == expectedId else {
            throw WatcherParseError.idDoesNotMatchExpectedId(declaredId: id, expectedId: expectedId)
        }

        let (systemPrompt, userPromptTemplate) = try splitSections(body)

        return WatcherDefinition(
            id: id,
            name: name,
            model: model,
            trigger: trigger,
            stateMode: stateMode,
            inputScope: inputScope,
            schema: schema,
            view: view,
            initialState: initialState,
            systemPrompt: systemPrompt,
            userPromptTemplate: userPromptTemplate
        )
    }

    // MARK: - `kind: simple` (`docs/design/34-simple-watchers.md` §2.1, §3.2)

    /// `schema`/`view`/`state_mode`/`initial_state` are desugared automatically by `SimpleWatcherSpec`
    /// and must not be hand-authored in a `kind: simple` file (§2.1: "レニエントにしない").
    private static let simpleUnsupportedFieldKeys = ["schema", "view", "state_mode", "initial_state"]

    private static func parseSimpleDefinition(mapping: Node.Mapping, body: String, expectedId: String) throws -> WatcherDefinition {
        for field in simpleUnsupportedFieldKeys where mapping[field] != nil {
            throw WatcherParseError.simpleUnsupportedField(field)
        }

        let id = try requiredString(mapping, key: "id")
        let name = try requiredString(mapping, key: "name")
        let model = mapping["model"]?.string
        let trigger = try parseTrigger(try requiredString(mapping, key: "trigger"))
        let inputScope = try parseInputScope(try requiredString(mapping, key: "input_scope"))

        guard id == expectedId else {
            throw WatcherParseError.idDoesNotMatchExpectedId(declaredId: id, expectedId: expectedId)
        }

        let prompt = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            throw WatcherParseError.simpleEmptyPrompt
        }

        let spec = SimpleWatcherSpec(
            id: id,
            name: name,
            model: model,
            trigger: trigger,
            inputScope: inputScope,
            prompt: prompt
        )
        return spec.desugar()
    }

    // MARK: - Frontmatter delimiter split (§4 step 1)

    private static func splitFrontmatter(_ text: String) throws -> (frontmatter: String, body: String) {
        let lines = text.components(separatedBy: "\n")
        guard let firstLine = lines.first, firstLine.trimmingCharacters(in: .whitespaces) == "---" else {
            throw WatcherParseError.missingFrontmatterDelimiter
        }
        guard let closingOffset = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            throw WatcherParseError.missingClosingFrontmatterDelimiter
        }
        let frontmatterLines = lines[1..<closingOffset]
        let bodyLines = lines[(closingOffset + 1)...]
        return (frontmatterLines.joined(separator: "\n"), bodyLines.joined(separator: "\n"))
    }

    // MARK: - trigger (§2.1)

    private static func parseTrigger(_ raw: String) throws -> WatcherTrigger {
        switch raw {
        case "on_summary_update":
            return .onSummaryUpdate
        case "on_session_end":
            return .onSessionEnd
        case "on_manual":
            return .onManual
        default:
            guard raw.hasPrefix("on_interval:") else {
                throw WatcherParseError.invalidTrigger(raw)
            }
            let secondsText = raw.dropFirst("on_interval:".count)
            guard let seconds = Int(secondsText) else {
                throw WatcherParseError.invalidIntervalSeconds(raw)
            }
            if seconds < minimumIntervalSeconds {
                logger.warning(
                    "on_interval seconds \(seconds, privacy: .public) is below the \(minimumIntervalSeconds, privacy: .public)-second minimum; clamping."
                )
            }
            return .onInterval(seconds: max(seconds, minimumIntervalSeconds))
        }
    }

    // MARK: - input_scope (`docs/design/34-simple-watchers.md` §5)

    /// Clamp range for `summary_and_recent:<n>`'s `<n>` (§5: "1〜200"). Values outside this range are
    /// clamped with a warning log rather than rejected -- execution continues (unlike `invalidRecentCount`,
    /// which is a hard parse error for non-numeric input).
    private static let recentCountRange = 1...200

    private static func parseInputScope(_ raw: String) throws -> WatcherInputScope {
        switch raw {
        case "summary":
            return .summary
        case "summary_and_recent":
            return .summaryAndRecent(count: WatcherInputScope.defaultRecentCount)
        case "full_refined":
            return .fullRefined
        default:
            guard raw.hasPrefix("summary_and_recent:") else {
                throw WatcherParseError.unknownInputScope(raw)
            }
            let countText = raw.dropFirst("summary_and_recent:".count)
            guard let count = Int(countText) else {
                throw WatcherParseError.invalidRecentCount(raw)
            }
            let clamped = min(max(count, recentCountRange.lowerBound), recentCountRange.upperBound)
            if clamped != count {
                logger.warning(
                    "summary_and_recent count \(count, privacy: .public) is out of range; clamping to \(clamped, privacy: .public)."
                )
            }
            return .summaryAndRecent(count: clamped)
        }
    }

    // MARK: - initial_state (§4 step 2)

    private static func parseInitialState(mapping: Node.Mapping, schema: WatcherSchema) throws -> JSONValue? {
        guard let initialStateText = mapping["initial_state"]?.string else {
            return nil
        }
        let parsed: JSONValue
        do {
            parsed = try JSONValue.parse(string: initialStateText)
        } catch {
            throw WatcherParseError.invalidInitialState(String(describing: error))
        }
        let errors = schema.validate(parsed)
        guard errors.isEmpty else {
            throw WatcherParseError.initialStateFailsSchemaValidation(errors)
        }
        return schema.canonicalize(parsed)
    }

    // MARK: - required string helper

    private static func requiredString(_ mapping: Node.Mapping, key: String) throws -> String {
        guard let value = mapping[key]?.string else {
            throw WatcherParseError.missingRequiredField(key)
        }
        return value
    }

    // MARK: - # System / # User sections (§4 step 3)

    private static func splitSections(_ body: String) throws -> (system: String, user: String) {
        var sections: [String: [String]] = [:]
        var currentHeading: String?
        for line in body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "# System" || trimmed == "# User" {
                let heading = String(trimmed.dropFirst(2))
                currentHeading = heading
                sections[heading] = []
                continue
            }
            if trimmed.hasPrefix("# ") {
                // Any other H1 heading ends whatever section preceded it; its lines are discarded
                // (§4 step 3: only "# System"/"# User" are recognized).
                currentHeading = nil
                continue
            }
            if let heading = currentHeading {
                sections[heading, default: []].append(line)
            }
        }
        guard let systemLines = sections["System"] else {
            throw WatcherParseError.missingSystemSection
        }
        guard let userLines = sections["User"] else {
            throw WatcherParseError.missingUserSection
        }
        return (
            systemLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
            userLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
