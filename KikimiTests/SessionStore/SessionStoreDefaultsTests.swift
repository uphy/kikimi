import Foundation
import Testing

@testable import Kikimi

/// Layer 1 (unit) coverage for `SessionStore+Defaults.swift`'s `createDraftSession(basedOn:)`
/// default-resolution helpers (`loadInitialContext`/`loadInitialSummaryTemplate`/
/// `loadInitialParticipantIds`/`loadInitialEnabledWatchers`), design doc section 8's failure-mode
/// table. `SessionStoreTests.swift` already covers the two extremes -- "everything missing" (empty
/// context / built-in template / no roster / empty watcher list) and "a live `basedOn` source with
/// every file readable" -- but not the fallback rungs in between: a `basedOn` source that itself
/// can't supply a file (missing directory, or a directory with no such file, or a corrupt one),
/// which must fall through to the *next* rung (global default, then built-in) rather than propagating
/// the failure. This file fills exactly those gaps, exercised only through `SessionStore`'s public
/// `createDraftSession(basedOn:)` API (same convention as `SessionStoreTests.swift`), never by
/// reaching into the `internal` `loadInitial*` helpers directly.
@Suite("SessionStore+Defaults (createDraftSession(basedOn:) fallback chain)")
struct SessionStoreDefaultsTests {
    // MARK: - Fixtures (mirrors SessionStoreTests.swift's own private helpers)

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionStoreDefaultsTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Same shape as `SessionStoreTests.makeStore(...)`: the default context/template/enabled-watchers
    /// files point at nonexistent paths under `root` unless overridden, so every fallback rung below
    /// `basedOn` is exercised deliberately, not accidentally.
    private func makeStore(
        defaultContextFileURL: URL? = nil,
        defaultSummaryTemplateFileURL: URL? = nil,
        defaultEnabledWatchersFileURL: URL? = nil
    ) -> (store: SessionStore, root: URL) {
        let root = makeTemporaryDirectory()
        let store = SessionStore(
            sessionsRootDirectory: root.appendingPathComponent("sessions", isDirectory: true),
            defaultContextFileURL: defaultContextFileURL ?? root.appendingPathComponent("missing-context.md"),
            defaultSummaryTemplateFileURL: defaultSummaryTemplateFileURL ?? root.appendingPathComponent("missing-template.md"),
            defaultEnabledWatchersFileURL: defaultEnabledWatchersFileURL ?? root.appendingPathComponent("missing-enabled.yaml")
        )
        return (store, root)
    }

    private func sessionDirectory(root: URL, sessionId: String) -> URL {
        root.appendingPathComponent("sessions", isDirectory: true).appendingPathComponent(sessionId, isDirectory: true)
    }

    // MARK: - loadInitialContext: basedOn a source that can't supply context.md

    @Test("createDraftSession(basedOn:) falls back to the global default context.md when the source session id has no session directory at all")
    func fallsBackToGlobalDefaultContextWhenSourceDirectoryMissing() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let globalDefaultContext = root.appendingPathComponent("global-context.md")
        try "# 全体デフォルトのメモ".write(to: globalDefaultContext, atomically: true, encoding: .utf8)

        let (store, _) = makeStoreRooted(at: root, defaultContextFileURL: globalDefaultContext)

        // No session with this id was ever created, so its directory (and context.md) never exists.
        let derived = try await store.createDraftSession(basedOn: "2020-01-01T00-00-00_nonexistent")
        #expect(derived.basedOnSession == "2020-01-01T00-00-00_nonexistent")

        let handle = try await store.openSession(derived.id)
        #expect(await handle.readContext() == "# 全体デフォルトのメモ")
    }

    @Test("createDraftSession(basedOn:) falls back to the global default context.md when the source session exists but has no readable context.md")
    func fallsBackToGlobalDefaultContextWhenSourceFileMissing() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let globalDefaultContext = root.appendingPathComponent("global-context.md")
        try "# 全体デフォルトのメモ".write(to: globalDefaultContext, atomically: true, encoding: .utf8)

        let (store, sessionsRoot) = makeStoreRooted(at: root, defaultContextFileURL: globalDefaultContext)

        let source = try await store.createDraftSession()
        // `writeContext` always creates context.md (even for empty content) during
        // `createDraftSession()`, so simulate "the source's context.md is unreadable" by removing it
        // out from under the source session after the fact.
        let sourceContextURL = sessionsRoot.appendingPathComponent(source.id, isDirectory: true).appendingPathComponent("context.md")
        try FileManager.default.removeItem(at: sourceContextURL)

        let derived = try await store.createDraftSession(basedOn: source.id)
        let handle = try await store.openSession(derived.id)
        #expect(await handle.readContext() == "# 全体デフォルトのメモ")
    }

    // MARK: - loadInitialSummaryTemplate: basedOn a source that can't supply summary_template.md

    @Test("createDraftSession(basedOn:) falls back to the global default summary_template.md when the source session id has no session directory at all")
    func fallsBackToGlobalDefaultTemplateWhenSourceDirectoryMissing() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let globalDefaultTemplate = root.appendingPathComponent("global-template.md")
        try "# {{title}}\n全体デフォルトテンプレート".write(to: globalDefaultTemplate, atomically: true, encoding: .utf8)

        let (store, _) = makeStoreRooted(at: root, defaultSummaryTemplateFileURL: globalDefaultTemplate)

        let derived = try await store.createDraftSession(basedOn: "2020-01-01T00-00-00_nonexistent")
        let handle = try await store.openSession(derived.id)
        #expect(await handle.readSummaryTemplate() == "# {{title}}\n全体デフォルトテンプレート")
    }

    @Test("createDraftSession(basedOn:) falls through source-missing and global-default-missing all the way to the built-in default summary template")
    func fallsBackToBuiltInTemplateWhenSourceAndGlobalDefaultBothMissing() async throws {
        let (store, _) = makeStore()

        let derived = try await store.createDraftSession(basedOn: "2020-01-01T00-00-00_nonexistent")
        let handle = try await store.openSession(derived.id)
        #expect(await handle.readSummaryTemplate() == SessionStore.builtInDefaultSummaryTemplate)
    }

    // MARK: - loadInitialParticipantIds: a corrupt participants.json must not fail the whole draft creation

    @Test("createDraftSession(basedOn:) writes no participants.json (rather than throwing) when the source session's participants.json is not valid JSON")
    func writesNoParticipantsFileWhenSourceParticipantsFileIsCorrupt() async throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = try await store.createDraftSession()
        let sourceDirectory = sessionDirectory(root: root, sessionId: source.id)
        let participantsURL = sourceDirectory.appendingPathComponent("participants.json")
        try "not valid json at all {{{".write(to: participantsURL, atomically: true, encoding: .utf8)

        // Must not throw despite the source's participants.json being corrupt.
        let derived = try await store.createDraftSession(basedOn: source.id)

        let derivedDirectory = sessionDirectory(root: root, sessionId: derived.id)
        #expect(!FileManager.default.fileExists(atPath: derivedDirectory.appendingPathComponent("participants.json").path))

        let handle = try await store.openSession(derived.id)
        let participants = await handle.readParticipants()
        #expect(participants.participantIds.isEmpty)
        #expect(participants.removedParticipantIds.isEmpty)
    }

    // MARK: - loadInitialEnabledWatchers: an unparsable default_watchers.yaml must fall back to an empty list

    @Test("createDraftSession seeds an empty watcher list (rather than throwing) when the default enabled-watchers file exists but is not valid YAML for its shape")
    func seedsEmptyWatcherListWhenDefaultFileHasWrongShape() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let defaultEnabledFile = root.appendingPathComponent("default_watchers.yaml")
        // `EnabledWatchersFile.enabled` is `[String]`; a scalar here is a type mismatch, not a missing
        // key, so this exercises the decode-failure branch specifically (not the file-missing one
        // `SessionStoreTests.enabledWatchersRoundTripsThroughYAML` already covers).
        try "enabled: 12345\n".write(to: defaultEnabledFile, atomically: true, encoding: .utf8)

        let (store, _) = makeStoreRooted(at: root, defaultEnabledWatchersFileURL: defaultEnabledFile)

        let meta = try await store.createDraftSession()
        let handle = try await store.openSession(meta.id)
        #expect(try await handle.readEnabledWatchers() == [])
    }

    // MARK: - Helpers

    /// Like `makeStore(...)` but rooted at a caller-supplied `root` (rather than a fresh one), so a
    /// test can seed a global-default fixture file under the same root before constructing the store.
    private func makeStoreRooted(
        at root: URL,
        defaultContextFileURL: URL? = nil,
        defaultSummaryTemplateFileURL: URL? = nil,
        defaultEnabledWatchersFileURL: URL? = nil
    ) -> (store: SessionStore, sessionsRoot: URL) {
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let store = SessionStore(
            sessionsRootDirectory: sessionsRoot,
            defaultContextFileURL: defaultContextFileURL ?? root.appendingPathComponent("missing-context.md"),
            defaultSummaryTemplateFileURL: defaultSummaryTemplateFileURL ?? root.appendingPathComponent("missing-template.md"),
            defaultEnabledWatchersFileURL: defaultEnabledWatchersFileURL ?? root.appendingPathComponent("missing-enabled.yaml")
        )
        return (store, sessionsRoot)
    }
}
