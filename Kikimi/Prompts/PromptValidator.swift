import Foundation
import Yams

// MARK: - PromptValidator

/// The shared ERROR/WARN/STALE judgment for prompt override files
/// (`docs/design/42-prompt-overrides.md` §4.1/§6.2/§8, `docs/prompts.md` "`--validate-prompts`").
/// `PromptStore` (runtime loading) and the headless `--validate-prompts` CLI both call
/// `validate(fileText:ref:)`/`validateAll(directory:)` rather than each re-deriving their own notion
/// of "is this override broken", so the two never drift (§4.1's requirement).
///
/// Delegates the ERROR-level judgment entirely to `PromptFile.parse(text:expectedID:spec:)` -- a
/// `PromptFileError` is exactly the set of defects `docs/prompts.md` documents as ERROR ("default に
/// フォールバックする不備"): frontmatter 不正・`prompt` 不一致・必須 placeholder 欠落・本文空. This
/// type only adds the WARN/STALE-level checks `PromptFile.parse` deliberately does not perform (§3.2's
/// frontmatter table: "権威はアプリ内の `PromptSpec` 一覧" -- `reload`/`placeholders` drift, unknown
/// `{{...}}` tokens, `based_on` staleness) plus `validateAll`'s directory walk and "無視される謎ファイル"
/// discovery.
enum PromptValidator {
    // MARK: Level

    /// §6.2's three severities. `.error` is the only one that causes the runtime to fall back to the
    /// built-in default (mirrors `PromptOverrideState.invalid`); `.warning` and `.stale` are
    /// informational -- the override still takes effect as written.
    enum Level: Sendable, Equatable {
        case error
        case warning
        case stale
    }

    // MARK: Finding

    /// One line of `--validate-prompts` output (§6.2: `"<LABEL> <path>: <message>"`).
    struct Finding: Sendable, Equatable {
        var level: Level
        /// The file's logical path under `prompts/`, e.g. `"prompts/refinement.md"` or
        /// `"prompts/dictation/apps/com.microsoft.VSCode.md"` (§3.1's disk layout). Always derived
        /// from a `PromptRef`/file name, never the absolute filesystem path `validateAll(directory:)`
        /// was called with -- so output (and this type's tests) stay stable across machines and
        /// `--prompts-dir` overrides.
        var path: String
        var message: String
    }

    // MARK: - validate(fileText:ref:)

    /// Validates a single override file's already-read contents against the `PromptSpec`/`PromptRef`
    /// it is expected to satisfy. Pure and stateless -- callers (`PromptStore`, `validateAll(directory:)`)
    /// own reading bytes off disk.
    static func validate(fileText: String, ref: PromptRef) -> [Finding] {
        let path = displayPath(for: ref)
        let promptID = expectedPromptID(for: ref)
        let promptSpec = spec(for: ref)

        switch PromptFile.parse(text: fileText, expectedID: promptID, spec: promptSpec) {
        case .failure(let error):
            // A `PromptFileError` means `PromptStore` would discard this file's contents entirely and
            // fall back to the built-in default (§8 #3-#6) -- nothing about the frontmatter/body can
            // be trusted enough to run the WARN-level checks below, so this is the only finding.
            return [Finding(level: .error, path: path, message: error.errorDescription ?? String(describing: error))]
        case .success(let parsed):
            var findings: [Finding] = []
            if parsed.wasClamped {
                findings.append(Finding(
                    level: .warning,
                    path: path,
                    message: "本文が \(PromptFile.maxBodyBytes / 1_024)KB を超えています。切り詰めて使用します。"
                ))
            }
            findings.append(contentsOf: basedOnFindings(spec: promptSpec, basedOn: parsed.basedOn, path: path))
            findings.append(contentsOf: driftFindings(fileText: fileText, spec: promptSpec, path: path))
            findings.append(contentsOf: unknownPlaceholderFindings(body: parsed.body, spec: promptSpec, path: path))
            return findings
        }
    }

    // MARK: - validateAll(directory:)

    /// Walks `directory` (a `prompts/` root) and validates every override file it recognizes, plus
    /// reports every entry it does not (§3.1: "上記一覧に無いファイル名は...`--validate-prompts` が担う").
    /// Tolerates a missing `directory` (or missing `dictation/`/`dictation/apps/` subdirectories) by
    /// simply finding nothing there -- `PromptStore` mkdir -p's all three at startup, but a caller
    /// pointing `--prompts-dir` at a fresh location should not crash.
    static func validateAll(directory: URL) -> [Finding] {
        var findings: [Finding] = []
        let fileManager = FileManager.default

        let knownFileNames = Set(PromptID.allCases.map { "\($0.rawValue).md" })
        for entryURL in sortedContents(of: directory) {
            let fileName = entryURL.lastPathComponent
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: entryURL.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                // `dictation/` is expected and walked separately below; any other subdirectory under
                // `prompts/` is unrecognized.
                if fileName != "dictation" {
                    findings.append(Finding(
                        level: .warning,
                        path: "prompts/\(fileName)/",
                        message: "prompts/ 配下の想定外のディレクトリです。無視されます。"
                    ))
                }
                continue
            }
            guard knownFileNames.contains(fileName),
                  let id = PromptID.allCases.first(where: { "\($0.rawValue).md" == fileName }) else {
                findings.append(Finding(
                    level: .warning,
                    path: "prompts/\(fileName)",
                    message: "prompts/ 配下の想定外のファイルです。無視されます。"
                ))
                continue
            }
            findings.append(contentsOf: validateFile(at: entryURL, ref: .builtin(id)))
        }

        let dictationDirectory = directory.appendingPathComponent("dictation", isDirectory: true)
        for entryURL in sortedContents(of: dictationDirectory) where entryURL.lastPathComponent != "apps" {
            findings.append(Finding(
                level: .warning,
                path: "prompts/dictation/\(entryURL.lastPathComponent)",
                message: "prompts/dictation/ 配下の想定外のエントリです。無視されます。"
            ))
        }

        let appsDirectory = dictationDirectory.appendingPathComponent("apps", isDirectory: true)
        for entryURL in sortedContents(of: appsDirectory) {
            let fileName = entryURL.lastPathComponent
            guard fileName.hasSuffix(".md") else {
                findings.append(Finding(
                    level: .warning,
                    path: "prompts/dictation/apps/\(fileName)",
                    message: "prompts/dictation/apps/ 配下の想定外のファイルです。無視されます。"
                ))
                continue
            }
            let bundleID = String(fileName.dropLast(".md".count))
            guard let ref = PromptRef(dictationAppBundleID: bundleID) else {
                findings.append(Finding(
                    level: .warning,
                    path: "prompts/dictation/apps/\(fileName)",
                    message: "bundle id \"\(bundleID)\" が [A-Za-z0-9._-]+ に一致しません。無視されます。"
                ))
                continue
            }
            findings.append(contentsOf: validateFile(at: entryURL, ref: ref))
        }

        return findings
    }

    // MARK: - directory walk helpers

    /// `contentsOfDirectory`, sorted by file name for deterministic output, or empty if `url` does not
    /// exist / is not a directory / is not readable.
    private static func sortedContents(of url: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        return entries.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Reads and validates the override file at `url` (already known to exist -- callers check that
    /// first, e.g. `validateAll(directory:)`'s directory walk or `PromptCLI`'s named-id lookup, since
    /// a missing file is "no override" (§3.1), not an ERROR). Exposed beyond `validateAll(directory:)`
    /// so `PromptCLI`'s `--validate-prompts <id>` path shares this exact UTF-8-failure handling instead
    /// of re-deriving its own (and silently dropping the ERROR finding on a non-UTF-8 file, §8 #2).
    static func validateFile(at url: URL, ref: PromptRef) -> [Finding] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            // Same I/O-layer failure `PromptStore` represents as `PromptFileError.fileNotUTF8` --
            // reuse its message rather than a hand-rolled one, so there is exactly one place that
            // owns this failure's wording regardless of which caller (runtime vs. CLI) hits it.
            return [Finding(
                level: .error,
                path: displayPath(for: ref),
                message: PromptFileError.fileNotUTF8.errorDescription ?? String(describing: PromptFileError.fileNotUTF8)
            )]
        }
        return validate(fileText: text, ref: ref)
    }

    // MARK: - ref → id/spec/path

    /// The `prompt:` frontmatter value (and `PromptFile.parse`'s `expectedID`) for `ref` (§3.1: "id は
    /// ファイルパスと 1:1"). Builtin ids are their raw value; the one variable id is
    /// `"dictation/apps/<bundle-id>"` (matching `PromptFile`'s own doc comment for this derivation).
    private static func expectedPromptID(for ref: PromptRef) -> String {
        switch ref {
        case .builtin(let id):
            return id.rawValue
        case .dictationApp(let bundleID):
            return "dictation/apps/\(bundleID)"
        }
    }

    /// `nil` for `.dictationApp` -- there is no `PromptSpec` entry for a per-app dictation context
    /// (`PromptSpec.swift`'s doc comment: "per-app 文脈は...default を持たない"), so required-placeholder
    /// checking and the `based_on`/`reload`/`placeholders` drift checks below all skip it, exactly as
    /// `PromptFile.parse` already does with a `nil` `spec`.
    private static func spec(for ref: PromptRef) -> PromptSpec? {
        switch ref {
        case .builtin(let id):
            return PromptSpec.spec(for: id)
        case .dictationApp:
            return nil
        }
    }

    private static func displayPath(for ref: PromptRef) -> String {
        "prompts/\(ref.relativePath)"
    }

    // MARK: - based_on / stale (§3.3, §8 #9)

    private static func basedOnFindings(spec: PromptSpec?, basedOn: String?, path: String) -> [Finding] {
        // Per-app dictation context has no default body to hash against (§2.2), so staleness is
        // undefined for it -- `based_on` is neither expected nor checked.
        guard let spec else { return [] }
        let currentHash = PromptSpec.defaultBodyHash(spec.id)
        guard let basedOn else {
            return [Finding(level: .warning, path: path, message: "\"based_on\" がありません。staleness を検出できません。")]
        }
        guard basedOn != currentHash else { return [] }
        return [Finding(level: .stale, path: path, message: "based_on \(basedOn) != current \(currentHash)")]
    }

    // MARK: - reload / placeholders drift (§3.2's frontmatter table)

    /// Re-parses the frontmatter mapping (already known to parse, since `PromptFile.parse` succeeded)
    /// purely to read `reload:`/`placeholders:` back for the drift comparison -- `PromptFile.Parsed`
    /// does not carry these informational-only fields, only the fields `PromptStore` actually needs at
    /// runtime.
    private static func driftFindings(fileText: String, spec: PromptSpec?, path: String) -> [Finding] {
        guard let spec, let mapping = frontmatterMapping(fileText) else { return [] }
        var findings: [Finding] = []

        if let declaredReload = mapping["reload"]?.string {
            let currentReload = spec.reload.rawValue
            if declaredReload != currentReload {
                findings.append(Finding(
                    level: .warning,
                    path: path,
                    message: "frontmatter の \"reload: \(declaredReload)\" が現在の reload \"\(currentReload)\" と一致しません。"
                ))
            }
        }

        if let placeholdersNode = mapping["placeholders"], case .mapping(let placeholdersMapping) = placeholdersNode {
            if let declaredRequired = stringSequence(placeholdersMapping["required"]),
               Set(declaredRequired) != Set(spec.requiredPlaceholders) {
                findings.append(Finding(
                    level: .warning,
                    path: path,
                    message: "frontmatter の \"placeholders.required\" \(quotedList(declaredRequired)) が現在の必須 placeholder " +
                        "\(quotedList(spec.requiredPlaceholders)) と一致しません。"
                ))
            }
            if let declaredOptional = stringSequence(placeholdersMapping["optional"]),
               Set(declaredOptional) != Set(spec.optionalPlaceholders) {
                findings.append(Finding(
                    level: .warning,
                    path: path,
                    message: "frontmatter の \"placeholders.optional\" \(quotedList(declaredOptional)) が現在の任意 placeholder " +
                        "\(quotedList(spec.optionalPlaceholders)) と一致しません。"
                ))
            }
        }

        return findings
    }

    private static func stringSequence(_ node: Node?) -> [String]? {
        guard case .sequence(let sequence)? = node else { return nil }
        return sequence.compactMap { $0.string }
    }

    private static func quotedList(_ items: [String]) -> String {
        "[" + items.map { "\"\($0)\"" }.joined(separator: ", ") + "]"
    }

    /// Same "`---` 区切りの YAML frontmatter" convention as `PromptFile`/`WatcherDefinitionParser`'s
    /// own private `splitFrontmatter`. Duplicated rather than shared (matching the existing precedent
    /// of each parser owning its own copy) since it is a small, self-contained helper and this type
    /// must not depend on `PromptFile`'s private implementation details.
    private static func frontmatterMapping(_ text: String) -> Node.Mapping? {
        let lines = text.components(separatedBy: "\n")
        guard let firstLine = lines.first, firstLine.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        guard let closingOffset = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return nil
        }
        let frontmatterText = lines[1..<closingOffset].joined(separator: "\n")
        guard let node = try? Yams.compose(yaml: frontmatterText), case .mapping(let mapping) = node else { return nil }
        return mapping
    }

    // MARK: - unknown placeholder tokens (§3.2, §8 #8)

    private static let placeholderTokenPattern = try! NSRegularExpression(pattern: "\\{\\{[^{}]+\\}\\}") // swiftlint:disable:this force_try

    private static func unknownPlaceholderFindings(body: String, spec: PromptSpec?, path: String) -> [Finding] {
        let known = Set((spec?.requiredPlaceholders ?? []) + (spec?.optionalPlaceholders ?? []))
        return unknownPlaceholderTokens(in: body, known: known).map {
            Finding(level: .warning, path: path, message: "未知の placeholder \($0) はそのまま文字として扱われます。")
        }
    }

    /// Every `{{...}}`-shaped token in `body` that is not in `known`, deduplicated and sorted for
    /// deterministic output (a body can repeat the same unrecognized token many times).
    private static func unknownPlaceholderTokens(in body: String, known: Set<String>) -> [String] {
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        var seen = Set<String>()
        var tokens: [String] = []
        for match in placeholderTokenPattern.matches(in: body, range: range) {
            guard let tokenRange = Range(match.range, in: body) else { continue }
            let token = String(body[tokenRange])
            guard !known.contains(token), seen.insert(token).inserted else { continue }
            tokens.append(token)
        }
        return tokens.sorted()
    }
}

// MARK: - PromptValidator.Level + label

extension PromptValidator.Level {
    /// The CLI's one-line-per-finding prefix (§6.2: `"ERROR <path>: ..."` / `"WARN <path>: ..."` /
    /// `"STALE <path>: ..."`). Defined here (rather than duplicated by the `--validate-prompts` CLI)
    /// so the exact label text has one source.
    var label: String {
        switch self {
        case .error:
            return "ERROR"
        case .warning:
            return "WARN"
        case .stale:
            return "STALE"
        }
    }
}
