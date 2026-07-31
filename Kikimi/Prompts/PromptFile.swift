import Foundation
import Yams

// MARK: - PromptFileError

/// Failure modes for `PromptFile.parse(text:expectedID:spec:)` (`docs/design/42-prompt-overrides.md`
/// §3.2, §8 #3–#6). Every case is a *validation* failure, not an I/O failure -- callers (`PromptStore`,
/// `--validate-prompts`) always react by logging a warning and falling back to
/// `PromptSpec.defaultBody`/`PromptOverrideState.invalid`; parsing never throws for "unknown, but
/// otherwise well-formed" content (unknown `{{...}}` tokens, `based_on`/`reload`/`placeholders`
/// drift) -- those are `PromptValidator`'s WARN-level findings, not parse errors.
enum PromptFileError: Error, Equatable, Sendable {
    /// No `---`-delimited frontmatter block at all: either the file doesn't start with a `---` line,
    /// or an opening `---` is never followed by a closing one (§8 #3).
    case frontmatterMissing
    /// The frontmatter block does not parse as YAML (§8 #3).
    case frontmatterInvalidYAML(String)
    /// The frontmatter parses as YAML but is not a mapping -- e.g. a bare scalar, a sequence, or an
    /// empty document (§8 #3).
    case frontmatterNotMapping
    /// The frontmatter has no `prompt:` field (§8 #4).
    case promptFieldMissing
    /// The frontmatter's `prompt:` field does not match the id derived from the file's path --
    /// copy/paste accident or manual rename (§3.2, §8 #4).
    case promptFieldMismatch(declared: String, expected: String)
    /// One or more of `PromptSpec.requiredPlaceholders` is missing from the trimmed body (e.g.
    /// `simple-watcher`'s `{{viewpoint}}`). Listed in declaration order (§2.1, §8 #5).
    case requiredPlaceholderMissing([String])
    /// The trimmed body is empty and the target id is not `dictation`/`dictation/apps/<bundle-id>`
    /// -- the only ids where an empty body is a valid "inject nothing" override (§3.2, §8 #6).
    case emptyBody
    /// The file's bytes could not be decoded as UTF-8 text (§8 #2). Never produced by
    /// `PromptFile.parse` itself -- that function only ever receives an already-decoded `String` --
    /// `PromptStore` constructs this case directly when reading raw bytes off disk fails before
    /// parsing can even begin, so the rest of the `PromptOverrideState`/logging machinery has one
    /// `PromptFileError` type to handle regardless of which layer (I/O vs. parse) the failure came
    /// from.
    case fileNotUTF8
}

// MARK: - PromptFileError + LocalizedError

extension PromptFileError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .frontmatterMissing:
            return "override ファイルの先頭に \"---\" で始まるfrontmatterがありません。"
        case .frontmatterInvalidYAML(let message):
            return "frontmatterのYAML解析に失敗しました: \(message)"
        case .frontmatterNotMapping:
            return "frontmatterはYAMLマッピングである必要があります。"
        case .promptFieldMissing:
            return "frontmatterに \"prompt\" フィールドがありません。"
        case .promptFieldMismatch(let declared, let expected):
            return "frontmatterの \"prompt: \(declared)\" が、このファイルが対象とするid \"\(expected)\" と一致しません。"
        case .requiredPlaceholderMissing(let placeholders):
            return "本文に必須のplaceholderがありません: \(placeholders.joined(separator: ", "))"
        case .emptyBody:
            return "本文が空です。"
        case .fileNotUTF8:
            return "ファイルをUTF-8テキストとして読み込めませんでした。"
        }
    }
}

// MARK: - PromptFile

/// Parses / serializes a `prompts/<id>.md` override file's "`---` 区切りの YAML frontmatter + 本文"
/// format (`docs/design/42-prompt-overrides.md` §3.2, §4.1) -- the same shape as a Watcher `.md`
/// (`WatcherDefinitionParser`), but for the much smaller prompt-override frontmatter schema.
///
/// Pure by construction: no file I/O, no logging. `PromptStore` (I/O + watch + state) and the
/// `--eject-prompt`/`--validate-prompts` CLI are the callers; they own reading bytes off disk,
/// deciding what a `PromptFileError`/clamp/missing-`based_on` means for `PromptOverrideState`, and
/// emitting the §8-mandated warning logs.
enum PromptFile {
    /// Prompt override body byte limit (§3.2: "32KB（UTF-8 バイト）を超えたら warning + clamp して使う",
    /// same numeric limit as `RefinementPromptBuilder.maxContextBytes` for `context.md`, but a
    /// distinct constant -- the two files are unrelated and could diverge independently).
    static let maxBodyBytes = 32 * 1_024

    /// One prompt-override id family that is allowed an empty body (§3.2: "空 = 文脈を一切注入しない",
    /// design 25 R17's escape hatch). `dictation` itself and every `dictation/apps/<bundle-id>` share
    /// this rule; every other id treats an empty trimmed body as `PromptFileError.emptyBody`.
    private static let dictationAppIDPrefix = "dictation/apps/"

    /// A successfully parsed and validated override file (§3.2).
    struct Parsed: Equatable, Sendable {
        /// The policy-layer body to use at runtime: trimmed of leading/trailing whitespace and
        /// newlines, and clamped to `maxBodyBytes` UTF-8 bytes if the trimmed body exceeded that
        /// limit. Placeholder tokens (`{{...}}`) are left exactly as written -- substitution is
        /// `PromptPlaceholder`'s job, not this parser's.
        var body: String
        /// `true` when the trimmed body exceeded `maxBodyBytes` and `body` was clamped as a result.
        /// Callers should log the §8 #7 warning when this is `true`.
        var wasClamped: Bool
        /// The frontmatter's `based_on` hash, verbatim, or `nil` when the field is absent. A `nil`
        /// value does not invalidate the file (§3.2: "`based_on` 欠落は warning") -- callers should
        /// log that warning themselves; staleness detection just becomes unavailable for this file.
        var basedOn: String?
    }

    /// Parses `text` as a prompt override file.
    ///
    /// - Parameters:
    ///   - text: The `.md` file's full contents.
    ///   - expectedID: The id this file is expected to declare in `prompt:` -- derived from its path
    ///     (`prompts/<id>.md` / `prompts/dictation/apps/<bundle-id>.md` → id `dictation/apps/<bundle-id>`,
    ///     §3.1). Also used (independent of `spec`) to decide whether an empty body is valid: only
    ///     `"dictation"` and ids with the `"dictation/apps/"` prefix allow it (§3.2, §8 #6). Callers
    ///     pass the id they looked the text up by, not a filename, so this parser stays
    ///     filesystem-agnostic -- the same convention `WatcherDefinitionParser.parse(text:expectedId:)`
    ///     uses.
    ///   - spec: The target id's `PromptSpec`, when known. `nil` for ids `PromptSpec` has no entry for
    ///     (currently only `dictation/apps/<bundle-id>`, which has no required placeholders and no
    ///     default body) -- required-placeholder checking is then skipped rather than failing closed,
    ///     since there is nothing to check against.
    static func parse(text: String, expectedID: String, spec: PromptSpec?) -> Result<Parsed, PromptFileError> {
        guard let (frontmatterText, rawBody) = splitFrontmatter(text) else {
            return .failure(.frontmatterMissing)
        }

        let frontmatterNode: Node?
        do {
            frontmatterNode = try Yams.compose(yaml: frontmatterText)
        } catch {
            return .failure(.frontmatterInvalidYAML(String(describing: error)))
        }
        guard let node = frontmatterNode, case .mapping(let mapping) = node else {
            return .failure(.frontmatterNotMapping)
        }

        guard let declaredID = mapping["prompt"]?.string else {
            return .failure(.promptFieldMissing)
        }
        guard declaredID == expectedID else {
            return .failure(.promptFieldMismatch(declared: declaredID, expected: expectedID))
        }
        let basedOn = mapping["based_on"]?.string

        let trimmedBody = rawBody.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowsEmptyBody = expectedID == "dictation" || expectedID.hasPrefix(dictationAppIDPrefix)
        guard !trimmedBody.isEmpty || allowsEmptyBody else {
            return .failure(.emptyBody)
        }

        // Clamp before the required-placeholder check: the check must run against the body that will
        // actually execute. Checking pre-clamp would let a >32KB file whose required placeholder sits
        // beyond the clamp boundary parse as `.active` and then run without that placeholder --
        // silently, with only the clamp warning (§8 #5's invalid-fallback would never fire).
        let (clampedBody, wasClamped) = RefinementPromptBuilder.clampToByteLimit(trimmedBody, limit: maxBodyBytes)

        if let requiredPlaceholders = spec?.requiredPlaceholders, !requiredPlaceholders.isEmpty {
            let missing = requiredPlaceholders.filter { !clampedBody.contains($0) }
            guard missing.isEmpty else {
                return .failure(.requiredPlaceholderMissing(missing))
            }
        }

        return .success(Parsed(body: clampedBody, wasClamped: wasClamped, basedOn: basedOn))
    }

    /// Renders `body` as a fully commented override file for `id`, in the shape `--eject-prompt`
    /// and `PromptStore.writeOverride` write to disk (§3.2's worked example). `spec` supplies every
    /// frontmatter field that is authoritative on the app side (`reload`, `placeholders`,
    /// `ejectComments`) and the `based_on` hash source (`PromptSpec.defaultBodyHash(spec.id)`, §3.3)
    /// -- `based_on` always reflects the *current* default body hash at render time, regardless of
    /// whether `body` itself is the untouched default (eject) or a customized override
    /// (`writeOverride`), so a later `--validate-prompts` run can detect drift against the default
    /// that was in effect when this file was written.
    static func render(id: String, spec: PromptSpec, body: String) -> String {
        let basedOnHash = PromptSpec.defaultBodyHash(spec.id)
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)

        var lines: [String] = [
            "# Kikimi のプロンプト override ファイル。削除するとアプリ内蔵の既定プロンプトに戻ります。",
            "# 編集の作法: このファイルは `--eject-prompt` で生成し、編集後に `--validate-prompts` で検証すること。",
            "prompt: \(id)",
            "based_on: \(basedOnHash)        # eject 元 default 本文の SHA-256 先頭 12 桁（staleness 検出用）",
            "reload: \(reloadText(spec.reload))          # このプロンプトの反映タイミング（アプリ側仕様の写し。参考情報）",
            "placeholders:",
            "  required: \(yamlStringArray(spec.requiredPlaceholders))" +
                (spec.requiredPlaceholders.isEmpty ? "" : "  # 本文に必ず残すこと。欠けると override 全体が無効になり default に戻る"),
            "  optional: \(yamlStringArray(spec.optionalPlaceholders))"
        ]
        for comment in spec.ejectComments {
            for line in comment.split(separator: "\n", omittingEmptySubsequences: false) {
                lines.append("# \(line)")
            }
        }

        let frontmatter = lines.joined(separator: "\n")
        return "---\n\(frontmatter)\n---\n\n\(trimmedBody)\n"
    }

    /// Renders a `dictation/apps/<bundle-id>` override file. This id family deliberately does not go
    /// through `render(id:spec:body:)`: it has no real `PromptSpec`, and `render`'s `based_on` hash
    /// always comes from `PromptSpec.defaultBodyHash` -- for a per-app file that would be some *other*
    /// prompt's default hash, misleading rather than merely absent. Omitting `based_on` entirely is
    /// the honest "no default to diff against". `PromptFile.parse` only requires a `prompt:` key
    /// inside a valid YAML mapping, so this shape round-trips exactly like a `render`-produced file.
    /// Shared by `DictationPromptMigration` and `PromptStore.writeOverride` so migration-produced and
    /// Settings-UI-produced per-app files carry identical frontmatter.
    static func renderDictationApp(bundleID: String, comment: String, body: String) -> String {
        let lines: [String] = [
            "---",
            "# \(comment)",
            "prompt: \(dictationAppIDPrefix)\(bundleID)",
            "reload: immediate",
            "placeholders:",
            "  required: []",
            "  optional: []",
            "---",
            "",
            body.trimmingCharacters(in: .whitespacesAndNewlines)
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Frontmatter delimiter split

    /// Same convention as `WatcherDefinitionParser.splitFrontmatter(_:)`: the first line must be
    /// exactly `---` (surrounding horizontal whitespace ignored), and a later line must close it.
    private static func splitFrontmatter(_ text: String) -> (frontmatter: String, body: String)? {
        let lines = text.components(separatedBy: "\n")
        guard let firstLine = lines.first, firstLine.trimmingCharacters(in: .whitespaces) == "---" else {
            return nil
        }
        guard let closingOffset = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return nil
        }
        let frontmatterLines = lines[1..<closingOffset]
        let bodyLines = lines[(closingOffset + 1)...]
        return (frontmatterLines.joined(separator: "\n"), bodyLines.joined(separator: "\n"))
    }

    // MARK: - render helpers

    private static func reloadText(_ reload: PromptReload) -> String {
        switch reload {
        case .immediate:
            return "immediate"
        case .sessionStart:
            return "session-start"
        }
    }

    private static func yamlStringArray(_ items: [String]) -> String {
        "[" + items.map { "\"\($0)\"" }.joined(separator: ", ") + "]"
    }
}
