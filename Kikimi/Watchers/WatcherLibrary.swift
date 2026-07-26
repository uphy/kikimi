import Foundation
import OSLog

// MARK: - WatcherOrigin

/// Where a Watcher's definition came from. Shared by `WatcherLibrary.resolveDefinitionText(id:sessionHandle:)`
/// and `WatcherPanelItem` (the UI layer's model, a later task) so both describe the same three
/// possibilities with one type (`docs/design/05-watcher-runner.md` §2.5).
enum WatcherOrigin: Sendable, Equatable {
    case preset
    case sessionLocal
    /// `enabled.yaml` lists this id, but neither a session-local nor a preset definition exists for
    /// it. Callers display this as an error badge rather than silently dropping the entry (kikimi.md
    /// 9 章's Watchers-tab table: "見つかりません").
    case missing
}

// MARK: - WatcherLibrary

/// Resolves Watcher definition text across the two-layer preset/session-local model (kikimi.md 9 章
/// "2種類の Watcher", `docs/design/05-watcher-runner.md` §3). Stateless beyond `presetsDirectory` --
/// every lookup re-reads disk, matching `WatcherDefinition`'s own "never cached" contract.
struct WatcherLibrary: Sendable {
    /// `config.yaml`'s `watchers.presets_dir`, already tilde-expanded by the caller (§3.2).
    var presetsDirectory: URL

    private static let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "WatcherLibrary")

    /// Resolves `id`'s definition text: session-local first, then preset (kikimi.md 9 章 "同名 ID の
    /// 場合は session-local が優先"). Returns `nil` if neither exists -- the caller treats this as
    /// `WatcherOrigin.missing`.
    func resolveDefinitionText(id: String, sessionHandle: SessionHandle) async throws -> (text: String, origin: WatcherOrigin)? {
        if let sessionLocalText = try await sessionHandle.readText(.watcherDefinition(id: id)) {
            return (sessionLocalText, .sessionLocal)
        }
        if let presetText = presetText(id: id) {
            return (presetText, .preset)
        }
        return nil
    }

    /// Every preset id (`presetsDirectory`'s `*.md` files, filename stem only), sorted. Invalid
    /// filenames (per `SessionFile`'s watcher-id character rule -- ASCII letters/digits/hyphens
    /// only) are skipped with a `.warning` log rather than surfaced as an id a caller could then fail
    /// to resolve a path for (§3: "不正名は無視（warning）"). An unreadable `presetsDirectory` (§12's
    /// "presets_dir が読めない") returns an empty list with a `.warning` log rather than throwing --
    /// session-local Watchers still function normally.
    func listPresetIds() -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: presetsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            Self.logger.warning("Could not list the Watcher presets directory at \(presetsDirectory.path, privacy: .public); no presets available.")
            return []
        }
        return entries
            .filter { $0.pathExtension == "md" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .filter { isValidWatcherId($0) }
            .sorted()
    }

    /// Reads one preset's raw `.md` text by id, or `nil` if it doesn't exist/isn't readable.
    func presetText(id: String) -> String? {
        guard isValidWatcherId(id) else { return nil }
        let url = presetsDirectory.appendingPathComponent("\(id).md")
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Copies a preset into `sessionHandle`'s session-local `watchers/<id>.md` (kikimi.md 9 章
    /// "Preset を fork"). Overwrites any existing session-local definition under the same id --
    /// callers (`WatcherLibrary`'s consumer, the ViewModel layer) are expected to confirm that with
    /// the user first when it matters, mirroring `promote(id:from:)`'s unconditional-write contract.
    func fork(id: String, into sessionHandle: SessionHandle) async throws {
        guard let text = presetText(id: id) else {
            throw WatcherLibraryError.presetNotFound(id)
        }
        try await sessionHandle.writeText(text, to: .watcherDefinition(id: id))
    }

    /// Writes a session-local Watcher definition out to the global preset library (kikimi.md 9 章
    /// "Session-local Watcher の Preset への昇格"), unconditionally overwriting any existing preset
    /// under the same id. The overwrite-confirmation UX (§3's "昇格（promote）の上書き確認は UI 層の責務")
    /// belongs to the caller, not this type.
    func promote(id: String, from sessionHandle: SessionHandle) async throws {
        guard let text = try await sessionHandle.readText(.watcherDefinition(id: id)) else {
            throw WatcherLibraryError.sessionLocalNotFound(id)
        }
        guard isValidWatcherId(id) else {
            throw WatcherLibraryError.invalidWatcherId(id)
        }
        try FileManager.default.createDirectory(at: presetsDirectory, withIntermediateDirectories: true)
        let url = presetsDirectory.appendingPathComponent("\(id).md")
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Same character rule `SessionFile`'s watcher-id validation enforces (kikimi.md 9 章 "id は
    /// ファイル名の英数字・ハイフンのみ許容") -- kept as a private duplicate here (rather than reusing
    /// `SessionFile`'s `private` validator) since `WatcherLibrary` needs it for preset filenames,
    /// which never go through `SessionFile` at all.
    private func isValidWatcherId(_ id: String) -> Bool {
        !id.isEmpty && id.unicodeScalars.allSatisfy { scalar in
            ("a"..."z").contains(Character(scalar)) ||
                ("A"..."Z").contains(Character(scalar)) ||
                ("0"..."9").contains(Character(scalar)) ||
                scalar == "-"
        }
    }
}

// MARK: - WatcherLibraryError

enum WatcherLibraryError: LocalizedError, Equatable, Sendable {
    case presetNotFound(String)
    case sessionLocalNotFound(String)
    case invalidWatcherId(String)

    var errorDescription: String? {
        switch self {
        case .presetNotFound(let id):
            return "Preset Watcher \"\(id)\" was not found."
        case .sessionLocalNotFound(let id):
            return "Session-local Watcher \"\(id)\" was not found."
        case .invalidWatcherId(let id):
            return "Invalid watcher id \"\(id)\": only ASCII letters, digits, and hyphens are allowed."
        }
    }
}
