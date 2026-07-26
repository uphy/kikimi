import Foundation
import OSLog

// MARK: - Notification.Name

extension Notification.Name {
    /// Posted by `DictationHistoryStore.finalize(handle:entry:maxEntries:)` once `entry.json` has
    /// been written successfully (`docs/design/29-dictation-history.md` §5.1). Unlike
    /// `.kikimiLLMUsageRecorded`, this carries no `userInfo` -- dictation history has no per-session
    /// scope to filter by (design 29 §5.1: "sessionId フィルタは不要"); any open Dictation History
    /// window just reloads its full list.
    static let kikimiDictationHistoryRecorded = Notification.Name("io.github.uphy.Kikimi.dictationHistoryRecorded")
}

// MARK: - DictationHistoryStoring

/// Test seam for `DictationHistoryStore` (`docs/design/29-dictation-history.md` §5.1's "テスト seam:
/// ... protocol（`DictationHistoryStoring`、actor 準拠）として切る"). `EntryHandle`/`ListItem` are
/// concrete types shared between this protocol and `DictationHistoryStore` (not associated types),
/// so a hand-written test stub can vend/consume the exact same values production code does without
/// needing to be generic.
protocol DictationHistoryStoring: Actor {
    func beginEntry(startedAt: Date) throws -> DictationHistoryStore.EntryHandle
    func deleteEntry(id: String)
    func finalize(handle: DictationHistoryStore.EntryHandle, entry: DictationHistoryEntry, maxEntries: Int) throws
    func listEntries() -> [DictationHistoryStore.ListItem]
    func readEntry(id: String) throws -> DictationHistoryEntry
    func deleteAll() throws
}

// MARK: - DictationHistoryStore

/// Owns all file I/O for `~/.local/state/kikimi/dictation/history/` (`docs/design/29-dictation-
/// history.md` §5). An `actor` for the same reason `SessionHandle` is: every entry's directory
/// create/write/delete must be serialized so a `finalize(...)`'s prune step can never race a
/// concurrent `beginEntry(startedAt:)`/`deleteEntry(id:)`/`deleteAll()` into inconsistent state.
actor DictationHistoryStore: DictationHistoryStoring {
    // MARK: EntryHandle / ListItem

    /// A begun-but-not-yet-finalized entry's identity, returned by `beginEntry(startedAt:)` and
    /// threaded back through `finalize(handle:entry:maxEntries:)`.
    struct EntryHandle: Sendable {
        /// The folder name (`EntryIdNaming.makeId(for:)`'s output) and this entry's logical id.
        var id: String
        var directoryURL: URL
        /// `directoryURL/audio.wav`.
        var audioFileURL: URL
    }

    /// A row of the history list. Carries `llmUsage` so the footer summary (§6.3) can be aggregated
    /// from the list without re-reading every `entry.json`.
    struct ListItem: Sendable {
        var id: String
        var recordedAt: Date
        var finalText: String
        var durationMs: Int
        /// `DictationHistoryRefineOutcome.rawValue` (e.g. `"success"`, `"fallback"`, `"disabled"`).
        var refineOutcome: String
        /// `DictationHistoryInsertOutcome.rawValue` (e.g. `"inserted"`, `"aborted_and_stashed"`).
        var insertOutcome: String
        var llmUsage: LLMUsageRecord?
    }

    // MARK: StoreError

    enum StoreError: LocalizedError, Equatable, Sendable {
        case directoryCreationFailed(String)
        case entryNotFound(String)
        case invalidEntryId(String)
        /// `deleteAll()` deleted every entry it could, but one or more `removeItem` calls failed
        /// (§5.1: "`deleteAll` の失敗のみ Settings がアラートで表示する" -- this is what that alert
        /// surfaces).
        case deleteAllPartiallyFailed(failedIds: [String])

        var errorDescription: String? {
            switch self {
            case .directoryCreationFailed(let message):
                return "Failed to create the dictation history entry directory: \(message)"
            case .entryNotFound(let id):
                return "Dictation history entry not found: \(id)"
            case .invalidEntryId(let id):
                return "Invalid dictation history entry id: \(id)"
            case .deleteAllPartiallyFailed(let failedIds):
                return "Failed to delete \(failedIds.count) dictation history entry directory(ies): \(failedIds.joined(separator: ", "))"
            }
        }
    }

    static let shared = DictationHistoryStore(rootDirectory: DictationHistoryStore.defaultRootDirectory)

    private let rootDirectory: URL
    private let fileManager: FileManager
    private let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "DictationHistoryStore")

    /// Every entry currently between `beginEntry(startedAt:)` and its eventual
    /// `finalize(handle:entry:maxEntries:)`/`deleteEntry(id:)`. Always excluded from `finalize`'s
    /// prune step (including its orphan sweep) and from `deleteAll()` (§5.1's "アクティブエントリの
    /// 保護"). A `Set`, not a single optional id: `finalize` is fire-and-forget (§4.1), so §5.1's
    /// documented race -- "直前発話の prune 実行時点で次の発話の begun フォルダが存在する" -- can leave
    /// *two* entries active at once (the previous one still finishing its `finalize`, the next one
    /// already `beginEntry`'d); a single overwritable id would let the newer `beginEntry` evict the
    /// older entry's protection and have its own in-progress folder swept as an "orphan" by the
    /// older entry's still-running prune.
    private var activeEntryIds: Set<String> = []

    init(rootDirectory: URL, fileManager: FileManager = .default) {
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
    }

    static var defaultRootDirectory: URL {
        FileManager.realHomeDirectory.appendingPathComponent(".local/state/kikimi/dictation/history", isDirectory: true)
    }

    /// `defaultRootDirectory/id` -- the well-known entry folder for an id, without needing to hop
    /// through the actor. Used by the (synchronous, non-isolated) list/detail views (§6.2) for
    /// anything that only needs the path, not the actor's file I/O: "Finder で開く" / "パスをコピー"
    /// context menu actions (§6.2 addendum) hand this straight to `NSWorkspace`/`NSPasteboard`, and
    /// `audioFileURL(forId:)` below builds on it. Always resolves against `defaultRootDirectory` (the
    /// real `~/.local/state/kikimi/dictation/history`), not an injected root -- UI code only ever
    /// reads the real store's files.
    static func entryDirectoryURL(forId id: String) -> URL {
        defaultRootDirectory.appendingPathComponent(id, isDirectory: true)
    }

    /// `entryDirectoryURL(forId:)/audio.wav` -- the well-known audio path for an entry id. Mirrors how
    /// `EntryHandle.audioFileURL` is derived for entries this process itself began.
    static func audioFileURL(forId id: String) -> URL {
        entryDirectoryURL(forId: id).appendingPathComponent("audio.wav")
    }

    // MARK: beginEntry / deleteEntry

    /// Creates the entry directory (and `history/`'s parents, idempotently), marks it as the active
    /// entry, and returns its handle. Actor-isolated: callers hop with `await`.
    func beginEntry(startedAt: Date) throws -> EntryHandle {
        let id = EntryIdNaming.makeId(for: startedAt)
        let directoryURL = rootDirectory.appendingPathComponent(id, isDirectory: true)
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        } catch {
            logger.error(
                "Failed to create dictation history entry directory \(id, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            throw StoreError.directoryCreationFailed(String(describing: error))
        }
        activeEntryIds.insert(id)
        return EntryHandle(
            id: id,
            directoryURL: directoryURL,
            audioFileURL: directoryURL.appendingPathComponent("audio.wav")
        )
    }

    /// Deletes a begun-but-empty entry (DH10) or an entry the user removed from the list UI.
    /// Best-effort: failures are logged as warnings, never thrown. Validates `id` first (same as
    /// `readEntry(id:)`) since this is the other entry point that resolves a path from a UI-supplied
    /// id -- `removeEntryDirectory` must never be handed something like `".."` that resolves outside
    /// `rootDirectory`.
    func deleteEntry(id: String) {
        guard (try? validateEntryId(id)) != nil else {
            logger.warning("Refusing to delete dictation history entry with an invalid id: \(id, privacy: .public)")
            return
        }
        activeEntryIds.remove(id)
        removeEntryDirectory(id: id)
    }

    // MARK: finalize

    /// Writes `entry.json` (making the entry valid), clears the active-entry mark, then prunes
    /// entries beyond `maxEntries` and sweeps orphan folders (§5.2).
    func finalize(handle: EntryHandle, entry: DictationHistoryEntry, maxEntries: Int) throws {
        let entryJSONURL = handle.directoryURL.appendingPathComponent("entry.json")
        do {
            let data = try SessionJSONCoding.makeEncoder().encode(entry)
            try data.write(to: entryJSONURL, options: [.atomic])
        } catch {
            logger.error(
                "Failed to write entry.json for dictation history entry \(handle.id, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            // Clear the active mark even on failure: §4.4 states that a failed `finalize` leaves an
            // `entry.json`-less orphan folder for a *later* `finalize`'s prune step to sweep up
            // (§5.2). If this id stayed in `activeEntryIds`, it would be permanently excluded from
            // every future orphan sweep for the rest of this store instance's lifetime, leaking the
            // folder instead of letting it be reclaimed as designed.
            activeEntryIds.remove(handle.id)
            throw error
        }

        activeEntryIds.remove(handle.id)

        prune(maxEntries: maxEntries)

        NotificationCenter.default.post(name: .kikimiDictationHistoryRecorded, object: nil)
    }

    // MARK: listEntries / readEntry

    /// Lists valid entries (has `entry.json`), newest first. Broken entries are logged and skipped.
    /// Folders without an `entry.json` (in-flight/orphaned) are skipped silently -- that is an
    /// expected transient state, not corruption. The root not existing yet (very first launch, or
    /// `history.enabled` never turned on) is a normal case returning an empty list, not an error.
    func listEntries() -> [ListItem] {
        guard let directoryURLs = enumerateEntryDirectories() else { return [] }

        let decoder = SessionJSONCoding.makeDecoder()
        var items: [ListItem] = []
        for directoryURL in directoryURLs {
            let id = directoryURL.lastPathComponent
            let entryJSONURL = directoryURL.appendingPathComponent("entry.json")
            guard let data = try? Data(contentsOf: entryJSONURL) else {
                continue
            }
            do {
                let entry = try decoder.decode(DictationHistoryEntry.self, from: data)
                items.append(
                    ListItem(
                        id: id,
                        recordedAt: entry.recordedAt,
                        finalText: entry.finalText,
                        durationMs: entry.durationMs,
                        refineOutcome: entry.refineOutcome.rawValue,
                        insertOutcome: entry.insertOutcome.rawValue,
                        llmUsage: entry.llmUsage
                    )
                )
            } catch {
                logger.warning(
                    "Skipping dictation history entry with a corrupt entry.json: \(id, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
        }
        return items.sorted { $0.recordedAt > $1.recordedAt }
    }

    /// Reads one full entry for the detail pane.
    func readEntry(id: String) throws -> DictationHistoryEntry {
        try validateEntryId(id)
        let entryJSONURL = rootDirectory.appendingPathComponent(id, isDirectory: true).appendingPathComponent("entry.json")
        guard let data = try? Data(contentsOf: entryJSONURL) else {
            throw StoreError.entryNotFound(id)
        }
        return try SessionJSONCoding.makeDecoder().decode(DictationHistoryEntry.self, from: data)
    }

    /// Deletes everything under `history/` except the active entry (Settings の「履歴をすべて削除」).
    /// Continues past individual `removeItem` failures so one bad entry can't block the rest, but
    /// throws at the end if anything failed -- this is the one operation whose failure the caller
    /// (Settings) surfaces to the user, rather than logging and swallowing (§5.1).
    func deleteAll() throws {
        guard let directoryURLs = enumerateEntryDirectories() else { return }

        var failedIds: [String] = []
        for directoryURL in directoryURLs {
            let id = directoryURL.lastPathComponent
            guard !activeEntryIds.contains(id) else { continue }
            do {
                try fileManager.removeItem(at: directoryURL)
            } catch {
                logger.error(
                    "Failed to delete dictation history entry \(id, privacy: .public) during deleteAll: \(String(describing: error), privacy: .public)"
                )
                failedIds.append(id)
            }
        }
        guard failedIds.isEmpty else {
            throw StoreError.deleteAllPartiallyFailed(failedIds: failedIds)
        }
    }

    // MARK: Private helpers

    /// Rejects ids that are anything other than a single, safe path component when resolved under
    /// `rootDirectory` (mirrors `SessionIdValidation` for the same reason: `id` can arrive from the
    /// history list UI, and `URL.appendingPathComponent` does not normalize `..`).
    private func validateEntryId(_ id: String) throws {
        guard !id.isEmpty, id != ".", id != "..", !id.contains("/") else {
            throw StoreError.invalidEntryId(id)
        }
    }

    /// `finalize`'s prune step (§5.2): derives each candidate's `id`/`recordedAt`/`isComplete` from
    /// folder names and `entry.json` presence alone -- no `entry.json` decode -- then deletes
    /// whatever `DictationHistoryPruning.entriesToDelete` says to.
    ///
    /// Every currently-active id is filtered out of `existing` before it ever reaches
    /// `entriesToDelete` (passing `activeEntryId: nil`), rather than passing one active id through --
    /// `activeEntryIds` can hold more than one id at once (see its doc comment), but the shared pure
    /// function's signature only excludes a single id, so pre-filtering here is how every active
    /// entry stays protected regardless of how many there are.
    private func prune(maxEntries: Int) {
        guard let directoryURLs = enumerateEntryDirectories() else { return }

        let existing: [(id: String, recordedAt: Date, isComplete: Bool)] = directoryURLs.compactMap { directoryURL in
            let id = directoryURL.lastPathComponent
            guard !activeEntryIds.contains(id) else { return nil }
            let entryJSONURL = directoryURL.appendingPathComponent("entry.json")
            let isComplete = fileManager.fileExists(atPath: entryJSONURL.path)
            let recordedAt = EntryIdNaming.recordedAt(fromId: id) ?? Date.distantPast
            return (id: id, recordedAt: recordedAt, isComplete: isComplete)
        }

        let idsToDelete = DictationHistoryPruning.entriesToDelete(
            existing: existing,
            activeEntryId: nil,
            maxEntries: maxEntries
        )
        for id in idsToDelete {
            removeEntryDirectory(id: id)
        }
    }

    /// Best-effort directory removal shared by `deleteEntry(id:)` and `prune(maxEntries:)`: logs a
    /// warning on failure and never throws (DH6/§5.1 -- history bookkeeping must never block
    /// dictation's main path).
    private func removeEntryDirectory(id: String) {
        let directoryURL = rootDirectory.appendingPathComponent(id, isDirectory: true)
        do {
            try fileManager.removeItem(at: directoryURL)
        } catch {
            logger.warning(
                "Failed to delete dictation history entry \(id, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
    }

    /// Lists `rootDirectory`'s immediate subdirectories, or `nil` if the root doesn't exist yet (the
    /// normal "no history recorded yet" case, mirroring `SessionStore.listSessions()`'s handling of
    /// `NSFileReadNoSuchFileError`) or couldn't be listed for some other reason (logged as `.error`).
    private func enumerateEntryDirectories() -> [URL]? {
        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(at: rootDirectory, includingPropertiesForKeys: nil)
        } catch {
            if (error as NSError).code != NSFileReadNoSuchFileError {
                logger.error("Failed to list the dictation history root directory: \(String(describing: error), privacy: .public)")
            }
            return nil
        }
        return entries.filter { url in
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }
}
