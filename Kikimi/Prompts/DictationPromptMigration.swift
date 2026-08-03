import Foundation
import OSLog

// MARK: - DictationPromptMigration

/// One-time, non-interactive migration of `dictation.context` (`config.yaml`) into
/// `~/.config/kikimi/prompts/dictation.md` / `prompts/dictation/apps/<bundle-id>.md`
/// (`docs/design/42-prompt-overrides.md` §7.1). Called exactly once from the GUI's `PromptStore`
/// initialization, before that store's own directory scan (so a freshly-migrated override is
/// picked up on the very first read, not on a subsequent watch-triggered reload).
///
/// Deliberately does not go through `PromptStore.writeOverride`: `PromptStore` calls this migration
/// as (or immediately before) its own `init`, so there is no live `PromptStore` instance yet to
/// delegate to. `dictation.md` itself *does* reuse `PromptFile.render(id:spec:body:)` (the exact
/// `.dictation` `PromptSpec`, so `based_on` and `reload`/`placeholders` come out identical to what
/// `--eject-prompt dictation` or the Settings UI's `writeOverride` would produce -- only the
/// frontmatter comment differs, swapped for one noting this file's config.yaml provenance). Per-app
/// files go through `PromptFile.renderDictationApp(bundleID:comment:body:)` instead -- see that
/// function's doc comment for why this id family gets no `based_on` line at all.
///
/// **The comparison basis is always `PromptSpec.spec(for: .dictation).defaultBody`, never
/// `DictationContextConfig.default.global`.** The two used to be the same string, but
/// `DictationContextConfig.default.global` is `nil` now (`docs/design/42-prompt-overrides.md` §7.2)
/// -- the migrated-away default body lives in exactly one place, `PromptSpec`. Comparing against the
/// config type's own (now-`nil`) default would silently degrade the "is this the unmodified
/// default?" check to "is this non-nil?", which would freeze the *previous* app version's default
/// body into every unmodified user's `prompts/dictation.md` as an override the moment they upgrade
/// -- exactly the "default improvements stop reaching users" failure `docs/design/42-prompt-
/// overrides.md` §1 rejected disk-realized defaults specifically to avoid.
enum DictationPromptMigration {
    private static let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "DictationPromptMigration")

    /// Every *previous* shipped `dictation` default body, verbatim. `migrateGlobal` treats a
    /// config.yaml `global` matching any of these (trimmed) as "realized but unmodified" and skips
    /// migration, same as a match against the current default -- see the comment at the comparison
    /// site. `internal` (not `private`) so `PromptMigrationTests` can exercise the legacy path against
    /// the real constant instead of a copy that could drift.
    ///
    /// This list is closed: it holds the bodies a shipped version could actually have written into a
    /// `config.yaml`, i.e. the ones that were `DictationContextConfig.default.global` back when that
    /// property still had a value. It is `nil` now (`docs/design/42-prompt-overrides.md` §7.2), so
    /// later edits to `PromptSpec.dictationDefaultBody` -- including the 2026-08 【言い直しの処理】
    /// rework -- can never appear in a `config.yaml` and do **not** belong here; appending one would
    /// only add a dead entry.
    static let legacyDefaultBodies: [String] = [
        // The design-25 R17 body (`DictationContextConfig.default.global` in the config.yaml era),
        // superseded when the no-answering / self-correction / register-preservation rules were added.
        """
        【前提】
        - 入力は音声認識（ASR）の書き起こし結果である
        - 漢字変換・カタカナ表記・アルファベット表記は認識エンジンによる推測に過ぎず、誤っていることがある
        - 正しいのは「読み（発音）」であり、表記は前後の文脈から最も自然なものに再決定してよい

        【整形ルール】
        - フィラー（「えーと」「あの」など）を除去する
        - 句読点を補い、自然な日本語にする
        - 表記の置換は「読みが同じ・近い範囲」に限り自由に行ってよい。読みから離れた書き換えや新しい情報の追加は禁止する（ただし、アプリ向けの追加指示がある場合はそちらを優先する）
        - 同音・近音の誤変換は積極的に正しい表記へ修正する（例:「駅存」→「既存」、「支持」→「指示」）
        - 技術用語は文脈から判断できる場合、正式な表記に直す（例:「エルエルエム」→「LLM」、「ピーディエフ」→「PDF」）
        - 良い例:「駅存の実装」→「既存の実装」（読みが近く、文脈上「既存」が妥当）。悪い例:「ピーディf」→「prデータ」（読みが一致しない、ただの推測でしてはいけない）
        - 音声認識により助詞や単語が部分的に欠落し、文法的に不自然な箇所がある場合は、前後の文脈から自然に補って文法的に整った文章にする（例:「明日 会議 資料」→「明日の会議の資料」）
        - 欠落補完はあくまで文法的な穴埋めに留め、話者が言っていない新しい情報や結論を創作しない
        - 確信が持てない箇所（表記の候補に自信が持てない、または欠落補完で文意が推測できない場合など）は元の表現を残す
        """
    ]

    /// Runs the migration if `state.yaml`'s `dictation_prompts_migrated` marker is not already set.
    /// If the marker *is* already set, logs a one-time-per-launch debug note instead when
    /// `config.yaml` still has a `dictation.context` key present -- editing it further has no effect
    /// once migrated, and this is the only place that reminds anyone of that (§7.1's last bullet).
    /// The two are mutually exclusive within a single call: on the launch that actually performs the
    /// migration, `dictationContext` is about to be consumed (not ignored), so logging "already
    /// migrated" in that same call would be actively wrong.
    ///
    /// - Parameters:
    ///   - dictationContext: `AppConfig.shared.data.dictation.context`, decoded as-is (§7.2: `global`
    ///     is `String?`, `nil` meaning "key absent").
    ///   - promptsDirectory: `~/.config/kikimi/prompts/` (or a test's temporary override directory).
    ///     Assumed to already exist (`PromptStore` mkdir -p's the 3-level layout before calling this,
    ///     §5.1) -- this type creates `dictation/apps/` under it on demand if a per-app write needs
    ///     it, but never the top-level directory itself.
    ///   - appState: Where the `dictation_prompts_migrated` marker lives. Defaults to `.shared`;
    ///     tests pass a temporary-directory instance (mirrors every other `AppState`-consuming type's
    ///     DI seam).
    ///   - fileManager: Test seam for the existence checks (skip-if-destination-exists,
    ///     `write(_:to:fileManager:)`'s `createDirectory`) this type does before writing (§8 #14).
    ///     The actual override-file write itself still goes through `String.write(to:atomically:
    ///     encoding:)`, not this parameter, so simulating a write-time failure (as opposed to an
    ///     existence-check result) still requires a real, if adverse, filesystem state -- see
    ///     `PromptMigrationTests.writeFailureWithholdsMarker()`, which does exactly that by omitting
    ///     `promptsDirectory` itself. Defaults to `.default`.
    static func migrateIfNeeded(
        dictationContext: DictationContextConfig,
        promptsDirectory: URL,
        appState: AppState = .shared,
        fileManager: FileManager = .default
    ) {
        guard !appState.data.dictationPromptsMigrated else {
            logStaleConfigKeyIfPresent(dictationContext)
            return
        }

        let globalSucceeded = migrateGlobal(dictationContext.global, promptsDirectory: promptsDirectory, fileManager: fileManager)
        let appsSucceeded = migrateApps(dictationContext.apps, promptsDirectory: promptsDirectory, fileManager: fileManager)

        // §8 #14: a write failure withholds the marker entirely (not just for the id that failed) so
        // the *whole* migration retries next launch -- a half-migrated state (global written, an app
        // entry silently dropped because its write failed) must not look "done".
        guard globalSucceeded, appsSucceeded else { return }
        appState.markDictationPromptsMigrated()
    }

    // MARK: - global

    /// §7.1's `dictation.context.global` migration decision + write. Returns `false` only when a
    /// write was attempted and failed; every "nothing to do" outcome (key absent, matches the
    /// current default, destination file already exists) returns `true` so it never blocks the
    /// marker on its own.
    private static func migrateGlobal(_ global: String?, promptsDirectory: URL, fileManager: FileManager) -> Bool {
        // Key absent (`init(from:)`'s plain `decodeIfPresent`, §7.2) -> never migrated.
        guard let global else { return true }

        var spec = PromptSpec.spec(for: .dictation)
        let trimmedGlobal = global.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDefault = spec.defaultBody.trimmingCharacters(in: .whitespacesAndNewlines)
        // Realized-but-unmodified default (e.g. a Settings save round-tripped the whole config,
        // writing the then-current default body back out verbatim) -> not migrated, so app upgrades
        // keep reaching this user's default (§1's whole reason disk-realized defaults were rejected).
        // The comparison covers `legacyDefaultBodies` too: a config.yaml written by an *older* app
        // version realized that version's default, and the current default may have been improved
        // since -- without the legacy check, such a user's unmodified old default would read as a
        // customization and get frozen into an override, cutting them off from the very improvement
        // that made the texts differ.
        let knownDefaults = [trimmedDefault] + legacyDefaultBodies.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !knownDefaults.contains(trimmedGlobal) else { return true }

        let destination = promptsDirectory.appendingPathComponent("dictation.md")
        guard !fileManager.fileExists(atPath: destination.path) else { return true }

        let isEmptyEscapeHatch = trimmedGlobal.isEmpty
        // Swap the spec's (empty, for `.dictation`) `ejectComments` for a migration-provenance note,
        // rendered into the frontmatter the same way a real `--eject-prompt`'s comments would be.
        spec.ejectComments = [
            isEmptyEscapeHatch
                ? "Migrated from config.yaml's dictation.context.global. The empty body is R17's escape "
                    + "hatch for injecting no dictation context at all -- delete this file to restore the "
                    + "built-in default instead."
                : "Migrated from config.yaml's dictation.context.global. This body is a user customization, "
                    + "not derived from the built-in default it is diffed against below (based_on)."
        ]

        // §3.2: the *empty* override is itself a valid, meaningful active override for `dictation`
        // (R17) -- write `""` verbatim rather than falling back to any placeholder text.
        // `PromptFile.render` trims this itself, so passing `global` (untrimmed) vs. `""` here is
        // equivalent for the empty-escape-hatch case; passing `global` unconditionally keeps this
        // branch-free.
        let text = PromptFile.render(id: "dictation", spec: spec, body: global)
        let succeeded = write(text, to: destination, fileManager: fileManager)
        if succeeded {
            logger.info("migrated dictation.context.global from config.yaml to \(destination.path, privacy: .public)")
        }
        return succeeded
    }

    // MARK: - apps

    /// §7.1's `dictation.context.apps[]` migration: each entry whose (trimmed) `context` is
    /// non-empty gets its own `prompts/dictation/apps/<bundle-id>.md`, skipped (not failed) when the
    /// bundle id is invalid or the destination already exists. Returns `false` only if a write was
    /// attempted and failed.
    private static func migrateApps(_ apps: [DictationAppContext], promptsDirectory: URL, fileManager: FileManager) -> Bool {
        var allSucceeded = true
        let appsDirectory = promptsDirectory.appendingPathComponent("dictation/apps", isDirectory: true)

        for app in apps {
            guard !app.context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            guard PromptRef.isValidBundleID(app.bundleID) else {
                logger.warning(
                    "dictation.context.apps bundle_id=\"\(app.bundleID, privacy: .public)\" is not a valid bundle id ([A-Za-z0-9._-]+); skipping its migration"
                )
                continue
            }

            let destination = appsDirectory.appendingPathComponent("\(app.bundleID).md")
            guard !fileManager.fileExists(atPath: destination.path) else { continue }

            let text = PromptFile.renderDictationApp(
                bundleID: app.bundleID,
                comment: "Migrated from config.yaml's dictation.context.apps[] entry for bundle_id: \(app.bundleID). "
                    + "Per-app dictation context has no built-in default -- this file's body is the migrated "
                    + "customization verbatim.",
                body: app.context
            )
            if write(text, to: destination, fileManager: fileManager, createIntermediateDirectories: true) {
                logger.info(
                    "migrated dictation.context.apps entry (bundle_id: \(app.bundleID, privacy: .public)) from config.yaml to \(destination.path, privacy: .public)"
                )
            } else {
                allSucceeded = false
            }
        }

        return allSucceeded
    }

    // MARK: - config.yaml drift note (§7.1's last bullet)

    /// Once migrated, further edits to `dictation.context` in `config.yaml` have no effect (this
    /// type never re-reads it after the marker is set). Logs a debug note once per launch whenever
    /// that key still carries data, so a chezmoi-managed / hand-edited `config.yaml` doesn't leave
    /// anyone wondering why their edit didn't take.
    private static func logStaleConfigKeyIfPresent(_ dictationContext: DictationContextConfig) {
        guard dictationContext.global != nil || !dictationContext.apps.isEmpty else { return }
        logger.debug(
            "config.yaml's dictation.context is present but has already been migrated to prompts/; this key is now ignored (docs/design/42-prompt-overrides.md §7.1)"
        )
    }

    // MARK: - file I/O

    private static func write(_ text: String, to url: URL, fileManager: FileManager, createIntermediateDirectories: Bool = false) -> Bool {
        do {
            if createIntermediateDirectories {
                try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            try text.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            logger.warning("failed to write a migrated prompt override to \(url.path, privacy: .public): \(String(describing: error), privacy: .public)")
            return false
        }
    }
}
