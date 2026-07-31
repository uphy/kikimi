import Foundation

// MARK: - PromptCLI

/// The headless `--eject-prompt` / `--validate-prompts` / `--render-prompt` / `--list-prompts`
/// entry point (`docs/design/42-prompt-overrides.md` §6). Called from `KikimiMain.main()` before
/// `KikimiApp.main()` ever runs, so none of this touches `AppConfig` / `AppState` /
/// `WindowManager` -- a `PromptStore` is constructed directly, rooted at `--prompts-dir` (default
/// `~/.config/kikimi/prompts/`), and all output goes to stdout/stderr (§6.1).
enum PromptCLI {
    // MARK: - IO

    /// Injectable stdout/stderr sinks, so tests can capture output without racing real process
    /// streams. Defaults write to the real `print`/`FileHandle.standardError`.
    struct IO {
        var stdout: (String) -> Void = { print($0) }
        var stderr: (String) -> Void = { message in
            FileHandle.standardError.write(Data((message + "\n").utf8))
        }
    }

    /// `~/.config/kikimi/prompts/` (`docs/design/42-prompt-overrides.md` §3.1), computed the same
    /// way every other Kikimi default directory is (`FileManager.realHomeDirectory`,
    /// `Kikimi/SessionStore/SessionStoreTypes.swift`) rather than reaching into `AppConfig`, which
    /// the headless CLI path must never touch (§6.1).
    static let defaultPromptsDirectory = FileManager.realHomeDirectory
        .appendingPathComponent(".config/kikimi/prompts", isDirectory: true)

    // MARK: - Entry point

    /// Returns an exit code when `arguments` names a recognized prompt subcommand
    /// (`--eject-prompt` / `--validate-prompts` / `--render-prompt` / `--list-prompts`); returns
    /// `nil` otherwise (`KikimiMain` falls through to the ordinary GUI launch). Every other token
    /// -- including macOS-injected flags such as `-NSDocumentRevisionsDebugMode YES` -- is silently
    /// skipped rather than rejected, so an unrelated launch is never mistaken for a malformed CLI
    /// invocation (§6.1).
    static func runIfRequested(arguments: [String], io: IO = IO()) -> Int32? {
        let parsed = parse(arguments)

        if let usageError = parsed.usageError {
            io.stderr(usageError)
            return 1
        }

        // No recognized prompt subcommand flag anywhere in `arguments`: this is not a prompt-CLI
        // invocation at all (§6.1's "自分の知らないフラグには反応せず nil を返す").
        guard let subcommand = parsed.subcommand else { return nil }

        let directory = parsed.promptsDirectory ?? defaultPromptsDirectory

        switch subcommand {
        case .eject(let id):
            return runEject(idArgument: id, force: parsed.force, outPath: parsed.outPath, directory: directory, io: io)
        case .validate(let ids):
            return runValidate(idArguments: ids, directory: directory, io: io)
        case .render(let id):
            return runRender(idArgument: id, directory: directory, io: io)
        case .list:
            return runList(directory: directory, io: io)
        }
    }

    // MARK: - Argument parsing

    private enum Subcommand {
        case eject(id: String)
        case validate(ids: [String])
        case render(id: String)
        case list
    }

    private struct ParsedArguments {
        var subcommand: Subcommand?
        var force = false
        var outPath: String?
        var promptsDirectory: URL?
        var usageError: String?
    }

    /// A single left-to-right pass. Recognized flags are consumed together with their value
    /// token(s); anything else (unknown flags, stray positional arguments) is skipped in place --
    /// this is what makes `-NS...`-style macOS-injected launch arguments harmless (§6.1).
    private static func parse(_ arguments: [String]) -> ParsedArguments {
        var result = ParsedArguments()
        var index = 0

        func isFlag(_ token: String) -> Bool { token.hasPrefix("--") }

        while index < arguments.count {
            let token = arguments[index]
            switch token {
            case "--eject-prompt":
                index += 1
                guard index < arguments.count, !isFlag(arguments[index]) else {
                    result.usageError = "--eject-prompt requires <id>"
                    continue
                }
                result.subcommand = .eject(id: arguments[index])
                index += 1

            case "--validate-prompts":
                index += 1
                var ids: [String] = []
                while index < arguments.count, !isFlag(arguments[index]) {
                    ids.append(arguments[index])
                    index += 1
                }
                result.subcommand = .validate(ids: ids)

            case "--render-prompt":
                index += 1
                guard index < arguments.count, !isFlag(arguments[index]) else {
                    result.usageError = "--render-prompt requires <id>"
                    continue
                }
                result.subcommand = .render(id: arguments[index])
                index += 1

            case "--list-prompts":
                result.subcommand = .list
                index += 1

            case "--force":
                result.force = true
                index += 1

            case "--out":
                index += 1
                guard index < arguments.count else {
                    result.usageError = "--out requires <path>"
                    continue
                }
                result.outPath = arguments[index]
                index += 1

            case "--prompts-dir":
                index += 1
                guard index < arguments.count else {
                    result.usageError = "--prompts-dir requires <path>"
                    continue
                }
                result.promptsDirectory = URL(fileURLWithPath: arguments[index])
                index += 1

            default:
                // Unknown flag or positional argument: not our concern (§6.1). Skipped, not an
                // error, so this invocation can still fall through to the GUI when no recognized
                // subcommand flag is found anywhere in `arguments`.
                index += 1
            }
        }

        return result
    }

    // MARK: - `PromptRef` <-> id string

    /// `<id>` argument parsing shared by all four subcommands: either a `PromptID` raw value
    /// (`"refinement"`, `"final-title"`, ...) or `"dictation/apps/<bundle-id>"` where `bundle-id`
    /// matches `[A-Za-z0-9._-]+` (§2.1/§3.1). Returns `nil` for anything else.
    private static func parseRef(_ idArgument: String) -> PromptRef? {
        if let id = PromptID(rawValue: idArgument) {
            return .builtin(id)
        }
        let dictationAppPrefix = "dictation/apps/"
        guard idArgument.hasPrefix(dictationAppPrefix) else { return nil }
        let bundleID = String(idArgument.dropFirst(dictationAppPrefix.count))
        // Reuses `PromptRef`'s own bundle-id validation (`PromptSpec.swift`) rather than a
        // second copy of the `[A-Za-z0-9._-]+` character class (§2.1) here.
        return PromptRef(dictationAppBundleID: bundleID)
    }

    /// `id → prompts/<id>.md` (§3.1): `prompts/refinement.md`, `prompts/dictation/apps/<bundle>.md`.
    /// Delegates to `PromptRef.relativePath` (`PromptSpec.swift`) rather than re-deriving the same
    /// mapping here.
    private static func path(for ref: PromptRef, in directory: URL) -> URL {
        directory.appendingPathComponent(ref.relativePath)
    }

    /// The canonical id string for a `PromptRef`, the inverse of `parseRef(_:)`.
    private static func idString(for ref: PromptRef) -> String {
        switch ref {
        case .builtin(let id):
            return id.rawValue
        case .dictationApp(let bundleID):
            return "dictation/apps/\(bundleID)"
        }
    }

    // MARK: - `--eject-prompt`

    private static func runEject(idArgument: String, force: Bool, outPath: String?, directory: URL, io: IO) -> Int32 {
        guard let ref = parseRef(idArgument) else {
            io.stderr("Unknown prompt id: \(idArgument)")
            return 1
        }

        let destination = outPath.map { URL(fileURLWithPath: $0) } ?? path(for: ref, in: directory)
        let fileManager = FileManager.default

        if !force, fileManager.fileExists(atPath: destination.path) {
            io.stderr("Prompt override already exists: \(destination.path) (use --force to overwrite)")
            return 2
        }

        let text: String
        switch ref {
        case .builtin(let id):
            let spec = PromptSpec.spec(for: id)
            text = PromptFile.render(id: id.rawValue, spec: spec, body: spec.defaultBody)
        case .dictationApp(let bundleID):
            // §2.2/§6.2: `dictation/apps/<bundle-id>` has no built-in default, so eject writes a
            // commented, empty-body skeleton instead of routing through `PromptFile.render` (which
            // always ties its `based_on` hash to a `PromptSpec.defaultBody` -- there is none here).
            text = dictationAppSkeletonText(bundleID: bundleID)
        }

        do {
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: destination, atomically: true, encoding: .utf8)
        } catch {
            io.stderr("Failed to write \(destination.path): \(error.localizedDescription)")
            return 1
        }

        io.stdout(destination.path)
        return 0
    }

    /// §3.2's frontmatter shape, hand-written for the one id family (`dictation/apps/<bundle-id>`)
    /// that has no `PromptSpec` to render from.
    private static func dictationAppSkeletonText(bundleID: String) -> String {
        """
        ---
        # Kikimi のプロンプト override ファイル。削除するとアプリ内蔵の既定プロンプトに戻ります。
        # 編集の作法: このファイルは `--eject-prompt` で生成し、編集後に `--validate-prompts` で検証すること。
        # 注意: dictation/apps/<bundle-id> には組み込みの default がありません。ここに書いた本文は、
        # グローバルな dictation 方針（prompts/dictation.md）に加えて、このアプリでのみ追加で適用される
        # 追加指示です。空のままでも有効な override として扱われます（「追加指示なし」）。
        prompt: dictation/apps/\(bundleID)
        reload: immediate
        placeholders:
          required: []
          optional: []
        ---

        """
    }

    // MARK: - `--validate-prompts`

    private static func runValidate(idArguments: [String], directory: URL, io: IO) -> Int32 {
        var findings: [PromptValidator.Finding] = []

        if idArguments.isEmpty {
            findings = PromptValidator.validateAll(directory: directory)
        } else {
            for idArgument in idArguments {
                guard let ref = parseRef(idArgument) else {
                    io.stderr("Unknown prompt id: \(idArgument)")
                    return 1
                }
                let fileURL = path(for: ref, in: directory)
                // No override file for this id: nothing to validate, and that is not itself an
                // error (§3.1: "ファイルなし = 組み込み default"). Existence is checked *before*
                // handing off to `PromptValidator.validateFile`, which -- like `PromptStore` --
                // treats "can't be read back as UTF-8" as an ERROR (§8 #2) rather than "absent";
                // reading the bytes here first and swallowing that failure the same way a missing
                // file is swallowed would silently drop that ERROR finding.
                guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }
                findings.append(contentsOf: PromptValidator.validateFile(at: fileURL, ref: ref))
            }
        }

        for finding in findings {
            io.stdout("\(finding.level.label) \(finding.path): \(finding.message)")
        }

        if findings.contains(where: { $0.level == .error }) {
            return 1
        }
        return findings.isEmpty ? 0 : 2
    }

    // MARK: - `--render-prompt`

    private static func runRender(idArgument: String, directory: URL, io: IO) -> Int32 {
        guard let id = PromptID(rawValue: idArgument) else {
            io.stderr("Unknown prompt id: \(idArgument)")
            return 1
        }

        let store = PromptStore(directory: directory)
        let ref = PromptRef.builtin(id)
        let state = store.overrideState(for: ref)

        if case .invalid(let error) = state {
            io.stderr("WARN \(path(for: ref, in: directory).path): invalid override, falling back to default (\(error))")
        }

        let policyBody = store.policyBody(for: ref)
        // §4.3: production resolves `refinement`'s/`dictation`'s glossary block through
        // `PromptStore.policyBody(for: .builtin(.glossaryHeader))` (`defaultRefinementQueueFactory`,
        // `DictationController`), not the hard-coded `GlossaryRenderer.defaultHeader` -- reading it
        // from the same `store` here keeps this render faithful to "ランタイムと同じ組み立て関数を通す"
        // (§6.2) when the caller also has an active `glossary-header` override.
        let glossaryHeaderBody = store.policyBody(for: .builtin(.glossaryHeader))
        io.stdout(renderedSystemPrompt(for: id, policyBody: policyBody, glossaryHeaderBody: glossaryHeaderBody))

        if case .invalid = state {
            return 2
        }
        return 0
    }

    /// Builds `id`'s final system prompt through the exact same builder functions the runtime
    /// call sites use (§4.2), fed with fixed, deterministic sample data (§6.2: "内蔵の決定論的サンプル
    /// データ"). `chat` and `final-title` have no contract layer (§2.2: "全文...なし"), so their
    /// rendered output is `policyBody` verbatim.
    private static func renderedSystemPrompt(for id: PromptID, policyBody: String, glossaryHeaderBody: String) -> String {
        switch id {
        case .refinement:
            return RefinementPromptBuilder.buildSystemPrompt(
                ruleBody: policyBody,
                context: sampleContextMarkdown,
                glossaryBlock: GlossaryRenderer.render(
                    entries: sampleGlossaryEntries,
                    categories: sampleGlossaryCategories,
                    header: glossaryHeaderBody
                ),
                dedupSystemLeakSegments: true
            ).prompt

        case .summary:
            return SummaryPromptBuilder.systemPrompt(policyBody: policyBody)

        case .chat, .finalTitle:
            return policyBody

        case .simpleWatcher:
            return SimpleWatcherSpec.systemPrompt(template: policyBody, viewpoint: sampleViewpoint)

        case .glossaryHeader:
            return GlossaryRenderer.render(
                entries: sampleGlossaryEntries,
                categories: sampleGlossaryCategories,
                header: policyBody
            ) ?? policyBody

        case .dictation:
            return DictationContextResolver.resolve(
                globalBody: policyBody,
                appBody: nil,
                glossary: sampleGlossaryEntries,
                glossaryCategories: sampleGlossaryCategories,
                glossaryHeader: glossaryHeaderBody
            ) ?? ""
        }
    }

    // MARK: - `--render-prompt` sample data (§6.2: "内蔵の決定論的サンプルデータ...`AppConfig` は読まない")

    private static let sampleContextMarkdown = """
    # 会議の目的
    新機能の要件定義を確定する。

    # 参加者
    - 田中（PM）
    - 佐藤（エンジニア）
    """

    private static let sampleViewpoint = "決定事項とネクストアクションをまとめてください。"

    private static let sampleGlossaryEntries: [GlossaryEntry] = [
        GlossaryEntry(term: "nekosuke", reading: "ねこすけ"),
        GlossaryEntry(term: "stg環境", reading: "ステージング環境"),
        GlossaryEntry(term: "PJX", reading: "")
    ]

    private static let sampleGlossaryCategories: [GlossaryCategory] = []

    // MARK: - `--list-prompts`

    private static func runList(directory: URL, io: IO) -> Int32 {
        let store = PromptStore(directory: directory)

        let refs: [PromptRef] = PromptID.allCases.map { .builtin($0) }
            + store.dictationAppBundleIDs().map { .dictationApp(bundleID: $0) }

        for ref in refs {
            io.stdout(listLine(ref: ref, state: store.overrideState(for: ref)))
        }

        return 0
    }

    private static func listLine(ref: PromptRef, state: PromptOverrideState) -> String {
        // `dictation/apps/<bundle-id>` has no `PromptSpec`/default body, so it is never stale --
        // only "override" or "default" applies (§6.2).
        let currentDefaultHash: String?
        if case .builtin(let id) = ref {
            currentDefaultHash = PromptSpec.defaultBodyHash(id)
        } else {
            currentDefaultHash = nil
        }

        let overrideColumn: String
        let stalenessColumn: String
        switch state {
        case .none:
            overrideColumn = "default"
            stalenessColumn = "-"
        case .active(_, let basedOn):
            overrideColumn = "override"
            if let basedOn, let currentDefaultHash {
                stalenessColumn = basedOn == currentDefaultHash ? "current" : "stale"
            } else {
                stalenessColumn = "-"
            }
        case .invalid:
            overrideColumn = "invalid"
            stalenessColumn = "-"
        }
        return "\(idString(for: ref))\t\(overrideColumn)\t\(stalenessColumn)"
    }
}
