import Foundation
import Testing

@testable import Kikimi

/// Layer 1 coverage for `DictationPromptMigration`'s one-time `dictation.context` ->
/// `prompts/dictation.md` / `prompts/dictation/apps/<bundle-id>.md` migration
/// (`docs/design/42-prompt-overrides.md` §7.1/§9.1). Every test roots `AppState` and the prompts
/// directory at a fresh temporary directory (mirrors `AppStateTests`'s DI pattern) so nothing here
/// ever touches a real `~/.config/kikimi`/`~/.local/state/kikimi`.
@Suite("DictationPromptMigration")
struct PromptMigrationTests {
    private func makeTemporaryDirectory(prefix: String = "PromptMigrationTests") -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The 3-level `prompts/` layout `PromptStore` mkdir -p's before calling this migration
    /// (§5.1) -- created up front here since `DictationPromptMigration` itself only creates
    /// `dictation/apps/` on demand for a per-app write, never the top-level directory.
    private func makePromptsDirectory(in root: URL) -> URL {
        let url = root.appendingPathComponent("prompts", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeAppState(in root: URL) -> AppState {
        AppState(directory: root.appendingPathComponent("state", isDirectory: true))
    }

    private func globalDestination(in promptsDirectory: URL) -> URL {
        promptsDirectory.appendingPathComponent("dictation.md")
    }

    private func appDestination(in promptsDirectory: URL, bundleID: String) -> URL {
        promptsDirectory.appendingPathComponent("dictation/apps/\(bundleID).md")
    }

    private func contents(of url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - global: key absent (§7.1's first bullet)

    @Test("global key absent (nil) -> not migrated, but the marker is still set (nothing failed)")
    func globalAbsentIsNotMigrated() {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let promptsDirectory = makePromptsDirectory(in: root)
        let appState = makeAppState(in: root)

        let context = DictationContextConfig(global: nil, apps: [])
        DictationPromptMigration.migrateIfNeeded(dictationContext: context, promptsDirectory: promptsDirectory, appState: appState)

        #expect(!FileManager.default.fileExists(atPath: globalDestination(in: promptsDirectory).path))
        #expect(appState.data.dictationPromptsMigrated == true)
    }

    // MARK: - global: matches the built-in default (§7.1's second bullet, the pinned regression)

    @Test(
        "global exactly matching PromptSpec(.dictation).defaultBody -> not migrated, even though this is what an unmodified config.yaml realized the default as"
    )
    func globalRealizedAsTheCurrentDefaultIsNotMigrated() {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let promptsDirectory = makePromptsDirectory(in: root)
        let appState = makeAppState(in: root)

        // This is exactly the scenario §7.1 calls out: a config.yaml that was saved (round-tripping
        // the whole file) back when the default body still lived at
        // `DictationContextConfig.default.global`, before that body moved to
        // `PromptSpec(.dictation).defaultBody`. The comparison basis must be the latter, or every
        // unmodified user's config.yaml would get frozen into a `prompts/dictation.md` override the
        // moment they upgrade -- exactly what §1 rejected disk-realized defaults to avoid.
        let context = DictationContextConfig(global: PromptSpec.spec(for: .dictation).defaultBody, apps: [])
        DictationPromptMigration.migrateIfNeeded(dictationContext: context, promptsDirectory: promptsDirectory, appState: appState)

        #expect(
            !FileManager.default.fileExists(atPath: globalDestination(in: promptsDirectory).path),
            "a config.yaml with the default body realized verbatim must not be migrated to an override"
        )
        #expect(appState.data.dictationPromptsMigrated == true)
    }

    @Test("global matching the default only after trimming surrounding whitespace -> still not migrated")
    func globalMatchingDefaultAfterTrimIsNotMigrated() {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let promptsDirectory = makePromptsDirectory(in: root)
        let appState = makeAppState(in: root)

        let context = DictationContextConfig(global: "\n  \(PromptSpec.spec(for: .dictation).defaultBody)  \n", apps: [])
        DictationPromptMigration.migrateIfNeeded(dictationContext: context, promptsDirectory: promptsDirectory, appState: appState)

        #expect(!FileManager.default.fileExists(atPath: globalDestination(in: promptsDirectory).path))
        #expect(appState.data.dictationPromptsMigrated == true)
    }

    @Test("global realizing a *legacy* shipped default -> not migrated, so old-version users keep following default improvements")
    func globalRealizedAsALegacyDefaultIsNotMigrated() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let promptsDirectory = makePromptsDirectory(in: root)
        let appState = makeAppState(in: root)

        // A config.yaml written by an older app version realized *that* version's default body.
        // The current default has been improved since, so the texts differ -- but the user never
        // customized anything, and freezing the old text as an override would cut them off from
        // exactly the improvement that made the texts differ.
        let legacyBody = try #require(DictationPromptMigration.legacyDefaultBodies.first)
        #expect(
            legacyBody.trimmingCharacters(in: .whitespacesAndNewlines)
                != PromptSpec.spec(for: .dictation).defaultBody.trimmingCharacters(in: .whitespacesAndNewlines),
            "the legacy list should only carry superseded bodies; an entry equal to the current default is dead weight"
        )

        let context = DictationContextConfig(global: legacyBody, apps: [])
        DictationPromptMigration.migrateIfNeeded(dictationContext: context, promptsDirectory: promptsDirectory, appState: appState)

        #expect(!FileManager.default.fileExists(atPath: globalDestination(in: promptsDirectory).path))
        #expect(appState.data.dictationPromptsMigrated == true)
    }

    // MARK: - global: present but empty (§7.1's third bullet, R17's escape hatch)

    @Test("global present but empty -> migrates to an empty-body override file (R17's escape hatch)")
    func emptyGlobalMigratesToEmptyOverride() {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let promptsDirectory = makePromptsDirectory(in: root)
        let appState = makeAppState(in: root)

        let context = DictationContextConfig(global: "", apps: [])
        DictationPromptMigration.migrateIfNeeded(dictationContext: context, promptsDirectory: promptsDirectory, appState: appState)

        let destination = globalDestination(in: promptsDirectory)
        #expect(FileManager.default.fileExists(atPath: destination.path))
        let text = contents(of: destination) ?? ""
        #expect(text.contains("prompt: dictation\n"))
        #expect(text.contains("based_on: \(PromptSpec.defaultBodyHash(.dictation))"))
        #expect(text.hasSuffix("---\n\n\n"), "the body after the closing frontmatter delimiter must be empty")
        #expect(appState.data.dictationPromptsMigrated == true)
    }

    @Test("global present but whitespace-only -> migrates to an empty-body override file, same as a bare empty string")
    func whitespaceOnlyGlobalMigratesToEmptyOverride() {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let promptsDirectory = makePromptsDirectory(in: root)
        let appState = makeAppState(in: root)

        let context = DictationContextConfig(global: "  \n\t  ", apps: [])
        DictationPromptMigration.migrateIfNeeded(dictationContext: context, promptsDirectory: promptsDirectory, appState: appState)

        let text = contents(of: globalDestination(in: promptsDirectory)) ?? ""
        #expect(text.hasSuffix("---\n\n\n"))
        #expect(appState.data.dictationPromptsMigrated == true)
    }

    // MARK: - global: customized (§7.1's fourth bullet)

    @Test("customized non-empty global -> migrates the body verbatim, tagged with the migration-time default's based_on hash")
    func customizedGlobalMigratesVerbatim() {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let promptsDirectory = makePromptsDirectory(in: root)
        let appState = makeAppState(in: root)

        let customBody = "この会議専用の追加ルール\n- 敬語で統一する"
        let context = DictationContextConfig(global: customBody, apps: [])
        DictationPromptMigration.migrateIfNeeded(dictationContext: context, promptsDirectory: promptsDirectory, appState: appState)

        let destination = globalDestination(in: promptsDirectory)
        let text = contents(of: destination) ?? ""
        #expect(text.contains("prompt: dictation\n"))
        #expect(
            text.contains("based_on: \(PromptSpec.defaultBodyHash(.dictation))"),
            "§7.1: based_on is the migration-time default hash even though this body is not derived from it"
        )
        #expect(text.hasSuffix("---\n\n\(customBody)\n"))
        #expect(appState.data.dictationPromptsMigrated == true)
    }

    // MARK: - global: destination already exists (§7.1's opening "対象ファイルが既に存在する id は常に skip")

    @Test("an existing prompts/dictation.md is left untouched, even if config.yaml still has a customized global")
    func existingGlobalOverrideFileIsNeverOverwritten() {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let promptsDirectory = makePromptsDirectory(in: root)
        let appState = makeAppState(in: root)

        let destination = globalDestination(in: promptsDirectory)
        let sentinel = "---\nprompt: dictation\n---\n\n既存のユーザー編集済みファイル\n"
        try! sentinel.write(to: destination, atomically: true, encoding: .utf8)

        let context = DictationContextConfig(global: "config.yaml側のカスタムルール", apps: [])
        DictationPromptMigration.migrateIfNeeded(dictationContext: context, promptsDirectory: promptsDirectory, appState: appState)

        #expect(contents(of: destination) == sentinel)
        #expect(appState.data.dictationPromptsMigrated == true)
    }

    // MARK: - the migrated marker (§7.1's framing bullet)

    @Test("an already-set marker suppresses migration entirely, even for an otherwise-migratable global")
    func alreadyMigratedMarkerSuppressesMigration() {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let promptsDirectory = makePromptsDirectory(in: root)
        let appState = makeAppState(in: root)
        appState.markDictationPromptsMigrated()

        let context = DictationContextConfig(global: "カスタムルール", apps: [])
        DictationPromptMigration.migrateIfNeeded(dictationContext: context, promptsDirectory: promptsDirectory, appState: appState)

        #expect(!FileManager.default.fileExists(atPath: globalDestination(in: promptsDirectory).path))
    }

    // MARK: - apps[] (§7.1's fifth bullet)

    @Test("a valid bundle id with non-empty context -> migrates verbatim to prompts/dictation/apps/<bundle-id>.md")
    func validAppEntryMigratesVerbatim() {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let promptsDirectory = makePromptsDirectory(in: root)
        let appState = makeAppState(in: root)

        let context = DictationContextConfig(
            global: nil,
            apps: [DictationAppContext(bundleID: "com.tinyspeck.slackmacgap", context: "絵文字は使わない")]
        )
        DictationPromptMigration.migrateIfNeeded(dictationContext: context, promptsDirectory: promptsDirectory, appState: appState)

        let destination = appDestination(in: promptsDirectory, bundleID: "com.tinyspeck.slackmacgap")
        let text = contents(of: destination) ?? ""
        #expect(text.contains("prompt: dictation/apps/com.tinyspeck.slackmacgap\n"))
        #expect(!text.contains("based_on:"), "per-app context has no built-in default at all")
        #expect(text.hasSuffix("---\n\n絵文字は使わない\n"))
        #expect(appState.data.dictationPromptsMigrated == true)
    }

    @Test("an invalid bundle id is skipped (warning), while sibling valid entries still migrate and the marker still gets set")
    func invalidBundleIDIsSkipped() {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let promptsDirectory = makePromptsDirectory(in: root)
        let appState = makeAppState(in: root)

        let context = DictationContextConfig(
            global: nil,
            apps: [
                DictationAppContext(bundleID: "not a bundle id / has spaces", context: "無効なbundle id"),
                DictationAppContext(bundleID: "com.apple.dt.Xcode", context: "コード用語はそのまま残す")
            ]
        )
        DictationPromptMigration.migrateIfNeeded(dictationContext: context, promptsDirectory: promptsDirectory, appState: appState)

        #expect(!FileManager.default.fileExists(atPath: appDestination(in: promptsDirectory, bundleID: "not a bundle id / has spaces").path))
        #expect(FileManager.default.fileExists(atPath: appDestination(in: promptsDirectory, bundleID: "com.apple.dt.Xcode").path))
        #expect(appState.data.dictationPromptsMigrated == true)
    }

    @Test("an app entry whose context is empty (or whitespace-only) after trimming is skipped, not migrated")
    func emptyAppContextIsSkipped() {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let promptsDirectory = makePromptsDirectory(in: root)
        let appState = makeAppState(in: root)

        let context = DictationContextConfig(
            global: nil,
            apps: [DictationAppContext(bundleID: "com.example.app", context: "   \n  ")]
        )
        DictationPromptMigration.migrateIfNeeded(dictationContext: context, promptsDirectory: promptsDirectory, appState: appState)

        #expect(!FileManager.default.fileExists(atPath: appDestination(in: promptsDirectory, bundleID: "com.example.app").path))
        #expect(appState.data.dictationPromptsMigrated == true)
    }

    @Test("an existing per-app override file is left untouched")
    func existingAppOverrideFileIsNeverOverwritten() {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let promptsDirectory = makePromptsDirectory(in: root)
        let appState = makeAppState(in: root)

        let destination = appDestination(in: promptsDirectory, bundleID: "com.example.app")
        try! FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sentinel = "---\nprompt: dictation/apps/com.example.app\n---\n\n既存のユーザー編集済みファイル\n"
        try! sentinel.write(to: destination, atomically: true, encoding: .utf8)

        let context = DictationContextConfig(
            global: nil,
            apps: [DictationAppContext(bundleID: "com.example.app", context: "config.yaml側の内容")]
        )
        DictationPromptMigration.migrateIfNeeded(dictationContext: context, promptsDirectory: promptsDirectory, appState: appState)

        #expect(contents(of: destination) == sentinel)
        #expect(appState.data.dictationPromptsMigrated == true)
    }

    // MARK: - global + apps together

    @Test("global and apps[] both migrate in the same run")
    func globalAndAppsBothMigrateTogether() {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let promptsDirectory = makePromptsDirectory(in: root)
        let appState = makeAppState(in: root)

        let context = DictationContextConfig(
            global: "共通ルール",
            apps: [DictationAppContext(bundleID: "com.example.app", context: "アプリ固有ルール")]
        )
        DictationPromptMigration.migrateIfNeeded(dictationContext: context, promptsDirectory: promptsDirectory, appState: appState)

        #expect(FileManager.default.fileExists(atPath: globalDestination(in: promptsDirectory).path))
        #expect(FileManager.default.fileExists(atPath: appDestination(in: promptsDirectory, bundleID: "com.example.app").path))
        #expect(appState.data.dictationPromptsMigrated == true)
    }

    // MARK: - write failure (§8 #14)

    @Test("a write failure withholds the marker entirely, so the next launch retries the whole migration")
    func writeFailureWithholdsMarker() {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // Deliberately do not create `prompts/` -- `text.write(to:)` for `dictation.md` then fails
        // with "no such directory", simulating §8 #14's write-failure mode without needing to mock
        // `FileManager` itself.
        let promptsDirectory = root.appendingPathComponent("prompts", isDirectory: true)
        let appState = makeAppState(in: root)

        let context = DictationContextConfig(global: "カスタムルール", apps: [])
        DictationPromptMigration.migrateIfNeeded(dictationContext: context, promptsDirectory: promptsDirectory, appState: appState)

        #expect(appState.data.dictationPromptsMigrated == false, "a failed write must not set the marker")
        #expect(!FileManager.default.fileExists(atPath: globalDestination(in: promptsDirectory).path))

        // The next "launch": `PromptStore`'s real mkdir -p would have created the directory by now,
        // so the retry succeeds.
        try! FileManager.default.createDirectory(at: promptsDirectory, withIntermediateDirectories: true)
        DictationPromptMigration.migrateIfNeeded(dictationContext: context, promptsDirectory: promptsDirectory, appState: appState)

        #expect(appState.data.dictationPromptsMigrated == true)
        #expect(FileManager.default.fileExists(atPath: globalDestination(in: promptsDirectory).path))
    }
}
