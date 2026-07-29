import Foundation
import OSLog
import Yams

// MARK: - SessionHandle + Generic Storage (summary.state.json / summary.md / watchers/*)

/// Generic persistence primitives for the session files `SessionHandle` doesn't otherwise expose a
/// dedicated API for: `summary.state.json`, `summary.md`, and `watchers/<id>.md` /
/// `watchers/<id>.state.json` (kikimi.md 8 章/9 章; `docs/design/07-session-store.md` section 11).
///
/// `SummaryUpdater` (`04-summary-updater.md`) and `WatcherRunner` (`05-watcher-runner.md`) own the
/// *content* of these files (the `summary.state.json` schema, patch application, view rendering,
/// Watcher schema validation, ...) — this file only owns *how it's persisted*, delegating the actual
/// atomic-write/crash-safety mechanics to the shared primitives `SessionHandle.swift` (core) already
/// implements on `SessionFile` (`atomicWriteJSON`/`readJSONIfPresent`/`atomicWriteText`/
/// `readTextIfPresent`). The public surface here is deliberately typed on the narrower
/// `GenericAccessibleFile`, not `SessionFile` itself, precisely so `.meta`/`.context`/
/// `.summaryTemplate`/`.transcriptJSONL`/`.refinedJSONL`/`.watchersEnabled` — each of which has its
/// own dedicated API with its own invariants (atomic read-modify-write, append-only, size-limit
/// warnings, YAML encoding, ...) — can never be passed into a raw overwrite by mistake; doing so is a
/// compile error rather than a runtime misuse (section 5.2.1).
extension SessionHandle {
    private static let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "SessionHandle.GenericStorage")

    // MARK: JSON (summary.state.json, watchers/<id>.state.json)

    /// Reads and decodes `file` as `T`. Returns `nil` if the file doesn't exist yet — the normal,
    /// expected case before a Watcher's first run or before the first summary update, not a failure
    /// (section 5.2/11: "存在しなければ nil を返す（初回実行前の Watcher 等、正常系として扱う）"). Any other
    /// read/decode failure (corrupt JSON, I/O error) is thrown rather than swallowed.
    func readJSON<T: Decodable>(_ file: GenericAccessibleFile, as type: T.Type) async throws -> T? {
        try readJSONIfPresent(file.asSessionFile, as: type)
    }

    /// Atomically overwrites `file` with the JSON encoding of `value` — never appends.
    /// `summary.state.json`/`watchers/<id>.state.json` are patch-applied-then-rewritten state
    /// snapshots, not logs (kikimi.md 8 章/9 章).
    func writeJSON<T: Encodable>(_ value: T, to file: GenericAccessibleFile) async throws {
        try atomicWriteJSON(value, to: file.asSessionFile)
    }

    // MARK: Text (summary.md, watchers/<id>.md)

    /// Reads `file` as UTF-8 text. Returns `nil` if it doesn't exist yet.
    func readText(_ file: GenericAccessibleFile) async throws -> String? {
        try readTextIfPresent(file.asSessionFile)
    }

    /// Atomically overwrites `file` with `text` — never appends (`summary.md` is fully re-rendered
    /// from `summary.state.json` on every update, and a Watcher's `.md` definition is edited as a
    /// whole document; kikimi.md 5 章/9 章).
    func writeText(_ text: String, to file: GenericAccessibleFile) async throws {
        try atomicWriteText(text, to: file.asSessionFile)
    }

    // MARK: File metadata

    /// `file`'s last-modified timestamp, or `nil` if it doesn't exist yet.
    ///
    /// Exists for one specific job: recovering a Watcher's "last run at" after the session is
    /// reopened. `watchers/<id>.state.json` holds only the LLM's output -- no timestamp -- so a
    /// reopened session used to render a Watcher's persisted result under a "未実行" footer
    /// (`MeetingWorkspaceViewModel.renderExistingState(for:)`). That file is written exactly once per
    /// successful run and never touched otherwise, so its mtime *is* the run's completion time.
    func modificationDate(of file: GenericAccessibleFile) async throws -> Date? {
        let url = directoryURL.appendingPathComponent(try file.relativePath())
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// Deletes `file` if it exists; a no-op (not an error) if it's already absent. Used for "local
    /// Watcher の削除" (kikimi.md 9 章 "Session-local Watcher の作り方"): removing both
    /// `watchers/<id>.md` and its `watchers/<id>.state.json` counterpart.
    func deleteFile(_ file: GenericAccessibleFile) async throws {
        let url = directoryURL.appendingPathComponent(try file.relativePath())
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    // MARK: watchers/enabled.yaml

    /// The Watcher IDs enabled for this session (kikimi.md 9 章 "セッション有効化リスト"). Returns an
    /// empty list if `enabled.yaml` doesn't exist yet, rather than throwing — a session whose
    /// `enabled.yaml` hasn't been seeded yet simply has no enabled Watchers.
    func readEnabledWatchers() async throws -> [String] {
        guard let yamlText = try readTextIfPresent(.watchersEnabled) else {
            return []
        }
        do {
            let decoded = try YAMLDecoder().decode(EnabledWatchersFile.self, from: yamlText)
            return decoded.enabled
        } catch {
            Self.logger.error(
                """
                Failed to parse watchers/enabled.yaml for session \(self.sessionId, privacy: .public): \
                \(String(describing: error), privacy: .public)
                """
            )
            throw error
        }
    }

    /// Atomically overwrites `watchers/enabled.yaml` with `ids` (kikimi.md 9 章). Encoded as a
    /// single `enabled:` key, matching the format `config.yaml`/`default_watchers.yaml` use.
    func writeEnabledWatchers(_ ids: [String]) async throws {
        let yamlText = try YAMLEncoder().encode(EnabledWatchersFile(enabled: ids))
        try atomicWriteText(yamlText, to: .watchersEnabled)
    }

    // MARK: watchers/*.md enumeration

    /// IDs of session-local Watcher definitions under `watchers/` — every `<id>.md` file, excluding
    /// `enabled.yaml` and any `<id>.state.json` file (kikimi.md 9 章 "Session-local Watcher の作り方").
    /// Returns an empty list if the `watchers/` directory doesn't exist yet (a session with no
    /// session-local Watchers at all).
    func listSessionLocalWatcherIds() async throws -> [String] {
        let watchersDirectory = try watchersDirectoryURL()
        guard FileManager.default.fileExists(atPath: watchersDirectory.path) else {
            return []
        }
        let entries = try FileManager.default.contentsOfDirectory(
            at: watchersDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return entries
            .filter { $0.pathExtension == "md" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    /// Resolves the `watchers/` directory by taking the parent of `watchers/enabled.yaml`'s own
    /// resolved path, rather than hardcoding `"watchers"` again here — `SessionFile` stays the one
    /// place that spells out the on-disk layout (see `SessionFile.swift`'s doc comment).
    private func watchersDirectoryURL() throws -> URL {
        directoryURL
            .appendingPathComponent(try SessionFile.watchersEnabled.relativePath())
            .deletingLastPathComponent()
    }
}
