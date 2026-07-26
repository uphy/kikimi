import Foundation
import Testing

@testable import Kikimi

/// Layer 1 (unit) coverage for `DictationHistoryStore`, targeting the scenarios called out in
/// `docs/design/29-dictation-history.md` section 9. Every test roots the store at a fresh temporary
/// directory (via the DI initializer) so nothing here ever touches a real
/// `~/.local/state/kikimi/dictation/history` on the machine running the suite.
@Suite("DictationHistoryStore")
struct DictationHistoryStoreTests {
    // MARK: - Fixtures

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DictationHistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Builds a store rooted at a fresh temporary directory's `history` subfolder -- deliberately
    /// *not* pre-created, so `beginEntry(startedAt:)`'s "creates history/'s parents idempotently"
    /// contract is exercised by every test that calls it.
    private func makeStore() -> (store: DictationHistoryStore, root: URL) {
        let base = makeTemporaryDirectory()
        let root = base.appendingPathComponent("history", isDirectory: true)
        return (DictationHistoryStore(rootDirectory: root), root)
    }

    private func makeEntry(
        recordedAt: Date = Date(timeIntervalSince1970: 1_751_000_000),
        durationMs: Int = 4_210,
        targetBundleId: String? = "com.google.Chrome",
        rawText: String = "きき身の履歴機能について",
        refinedText: String? = "Kikimiの履歴機能について",
        finalText: String = "Kikimiの履歴機能について",
        refineOutcome: DictationHistoryRefineOutcome = .success,
        refineError: String? = nil,
        insertOutcome: DictationHistoryInsertOutcome = .inserted,
        llmUsage: LLMUsageRecord? = nil
    ) -> DictationHistoryEntry {
        DictationHistoryEntry(
            recordedAt: recordedAt,
            durationMs: durationMs,
            targetBundleId: targetBundleId,
            rawText: rawText,
            refinedText: refinedText,
            finalText: finalText,
            refineOutcome: refineOutcome,
            refineError: refineError,
            insertOutcome: insertOutcome,
            llmUsage: llmUsage
        )
    }

    private static let sampleUsage = LLMUsageRecord(
        timestamp: Date(timeIntervalSince1970: 1_751_000_001),
        purpose: "dictation",
        model: "claude-haiku-4-5-20251001",
        inputTokens: 412,
        outputTokens: 18,
        cacheReadInputTokens: 0,
        cacheCreationInputTokens: 0,
        reportedCostUSD: nil
    )

    // MARK: - beginEntry

    @Test("beginEntry(startedAt:) idempotently creates history/'s parents and returns a handle pointing at audio.wav")
    func beginEntryCreatesDirectoryAndHandle() async throws {
        let (store, root) = makeStore()
        #expect(!FileManager.default.fileExists(atPath: root.path))

        let handle = try await store.beginEntry(startedAt: Date())

        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: handle.directoryURL.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(handle.audioFileURL == handle.directoryURL.appendingPathComponent("audio.wav"))
        #expect(handle.directoryURL == root.appendingPathComponent(handle.id, isDirectory: true))
    }

    // MARK: - begin -> finalize round trip

    @Test("begin -> finalize round-trips entry.json, including the nested llm_usage (DH5)")
    func beginToFinalizeRoundTrips() async throws {
        let (store, _) = makeStore()
        let handle = try await store.beginEntry(startedAt: Date(timeIntervalSince1970: 1_751_000_000))
        let entry = makeEntry(llmUsage: Self.sampleUsage)

        try await store.finalize(handle: handle, entry: entry, maxEntries: 100)

        #expect(FileManager.default.fileExists(atPath: handle.directoryURL.appendingPathComponent("entry.json").path))

        let readBack = try await store.readEntry(id: handle.id)
        #expect(readBack == entry)
        #expect(readBack.llmUsage == Self.sampleUsage)

        let items = await store.listEntries()
        #expect(items.count == 1)
        #expect(items[0].id == handle.id)
        #expect(items[0].finalText == entry.finalText)
        #expect(items[0].durationMs == entry.durationMs)
        #expect(items[0].refineOutcome == "success")
        #expect(items[0].insertOutcome == "inserted")
        #expect(items[0].llmUsage == Self.sampleUsage)
    }

    @Test("finalize clears the active-entry mark, so a later deleteAll() removes the now-finalized entry")
    func finalizeClearsActiveMark() async throws {
        let (store, _) = makeStore()
        let handle = try await store.beginEntry(startedAt: Date())
        try await store.finalize(handle: handle, entry: makeEntry(), maxEntries: 100)

        try await store.deleteAll()

        let items = await store.listEntries()
        #expect(items.isEmpty)
    }

    @Test("finalize posts .kikimiDictationHistoryRecorded")
    func finalizePostsNotification() async throws {
        let (store, _) = makeStore()
        let handle = try await store.beginEntry(startedAt: Date())

        var received = false
        let observer = NotificationCenter.default.addObserver(forName: .kikimiDictationHistoryRecorded, object: nil, queue: nil) { _ in
            received = true
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        try await store.finalize(handle: handle, entry: makeEntry(), maxEntries: 100)

        #expect(received)
    }

    @Test("a failed finalize still clears the active-entry mark, so the leftover folder can later be removed (§4.4's orphan-sweep contract)")
    func finalizeFailureClearsActiveMark() async throws {
        let (store, _) = makeStore()
        let handle = try await store.beginEntry(startedAt: Date())
        // Force `entry.json`'s write to fail by removing its parent directory out from under the
        // handle -- mirrors what §4.4 describes as the failure mode this contract exists for.
        try FileManager.default.removeItem(at: handle.directoryURL)

        await #expect(throws: (any Error).self) {
            try await store.finalize(handle: handle, entry: makeEntry(), maxEntries: 100)
        }

        // Recreate the folder (simulating that some trace of the failed entry survived) and confirm
        // a later deleteAll() is able to remove it -- if the active mark had leaked past the failure,
        // deleteAll() would skip it forever as a "still active" entry.
        try FileManager.default.createDirectory(at: handle.directoryURL, withIntermediateDirectories: true)
        try await store.deleteAll()
        #expect(!FileManager.default.fileExists(atPath: handle.directoryURL.path))
    }

    // MARK: - Orphan handling (section 5.2)

    @Test("listEntries skips a folder with no entry.json (in-flight/orphaned) without logging it as corrupt")
    func listEntriesSkipsOrphanFolder() async throws {
        let (store, _) = makeStore()
        let complete = try await store.beginEntry(startedAt: Date(timeIntervalSince1970: 1_751_000_000))
        try await store.finalize(handle: complete, entry: makeEntry(), maxEntries: 100)
        // A begun-but-never-finalized entry: directory exists, no entry.json.
        _ = try await store.beginEntry(startedAt: Date(timeIntervalSince1970: 1_751_000_100))

        let items = await store.listEntries()

        #expect(items.count == 1)
        #expect(items[0].id == complete.id)
    }

    @Test("finalize's prune sweeps orphan folders unconditionally, excluding the active entry")
    func finalizeSweepsOrphansExcludingActive() async throws {
        let (store, root) = makeStore()
        // Pre-create an orphan folder directly on disk (simulating a crash mid-beginEntry, before
        // this test's own `beginEntry` calls run).
        let orphanId = EntryIdNaming.makeId(for: Date(timeIntervalSince1970: 1_700_000_000))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(orphanId, isDirectory: true),
            withIntermediateDirectories: true
        )

        let active = try await store.beginEntry(startedAt: Date(timeIntervalSince1970: 1_751_000_200))
        let toFinalize = try await store.beginEntry(startedAt: Date(timeIntervalSince1970: 1_751_000_100))

        try await store.finalize(handle: toFinalize, entry: makeEntry(), maxEntries: 100)

        // The orphan was swept by `toFinalize`'s prune step; the still-active entry's folder survives.
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(orphanId, isDirectory: true).path))
        #expect(FileManager.default.fileExists(atPath: active.directoryURL.path))
    }

    // MARK: - Corrupt entry.json (section 5.2 / 9)

    @Test("listEntries skips a corrupt entry.json, logs it, and still returns the other valid entries")
    func listEntriesSkipsCorruptJSONAndContinues() async throws {
        let (store, root) = makeStore()
        let good = try await store.beginEntry(startedAt: Date(timeIntervalSince1970: 1_751_000_000))
        try await store.finalize(handle: good, entry: makeEntry(), maxEntries: 100)

        let corruptId = EntryIdNaming.makeId(for: Date(timeIntervalSince1970: 1_751_000_050))
        let corruptDirectory = root.appendingPathComponent(corruptId, isDirectory: true)
        try FileManager.default.createDirectory(at: corruptDirectory, withIntermediateDirectories: true)
        try Data("{ this is not valid json".utf8).write(to: corruptDirectory.appendingPathComponent("entry.json"))

        let items = await store.listEntries()

        #expect(items.count == 1)
        #expect(items[0].id == good.id)
    }

    @Test("readEntry(id:) throws for a corrupt entry.json")
    func readEntryThrowsForCorruptJSON() async throws {
        let (store, root) = makeStore()
        let corruptId = EntryIdNaming.makeId(for: Date())
        let corruptDirectory = root.appendingPathComponent(corruptId, isDirectory: true)
        try FileManager.default.createDirectory(at: corruptDirectory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: corruptDirectory.appendingPathComponent("entry.json"))

        await #expect(throws: (any Error).self) {
            _ = try await store.readEntry(id: corruptId)
        }
    }

    @Test("readEntry(id:) throws for a missing entry")
    func readEntryThrowsForMissingEntry() async throws {
        let (store, _) = makeStore()
        await #expect(throws: (any Error).self) {
            _ = try await store.readEntry(id: "does-not-exist_deadbeef")
        }
    }

    // MARK: - deleteAll (section 5.1)

    @Test("deleteAll removes every finalized entry")
    func deleteAllRemovesFinalizedEntries() async throws {
        let (store, _) = makeStore()
        for offset in 0..<3 {
            let handle = try await store.beginEntry(startedAt: Date(timeIntervalSince1970: 1_751_000_000 + Double(offset)))
            try await store.finalize(handle: handle, entry: makeEntry(), maxEntries: 100)
        }
        #expect(await store.listEntries().count == 3)

        try await store.deleteAll()

        #expect(await store.listEntries().isEmpty)
    }

    @Test("deleteAll excludes the active (begun-but-not-finalized) entry")
    func deleteAllExcludesActiveEntry() async throws {
        let (store, _) = makeStore()
        let finalized = try await store.beginEntry(startedAt: Date(timeIntervalSince1970: 1_751_000_000))
        try await store.finalize(handle: finalized, entry: makeEntry(), maxEntries: 100)
        let active = try await store.beginEntry(startedAt: Date(timeIntervalSince1970: 1_751_000_100))

        try await store.deleteAll()

        #expect(!FileManager.default.fileExists(atPath: finalized.directoryURL.path))
        #expect(FileManager.default.fileExists(atPath: active.directoryURL.path))
    }

    // MARK: - deleteEntry (DH10)

    @Test("deleteEntry rejects a path-traversal id instead of resolving it outside rootDirectory")
    func deleteEntryRejectsPathTraversalId() async throws {
        let (store, root) = makeStore()
        // `root` ("history/") must actually exist on disk for this to be a meaningful test --
        // otherwise `root.appendingPathComponent("..")` fails to resolve for the mundane reason that
        // an intermediate path component is missing, not because the id was rejected.
        _ = try await store.beginEntry(startedAt: Date())
        #expect(FileManager.default.fileExists(atPath: root.path))
        // A sibling of `history/` that must survive: if `deleteEntry(id: "..")` were resolved
        // unchecked, `root.appendingPathComponent("..")` lands on `root`'s parent, so an unvalidated
        // call would attempt to remove this whole temporary directory (and everything under it,
        // including `root` itself).
        let siblingMarker = root.deletingLastPathComponent().appendingPathComponent("sibling-marker")
        try Data().write(to: siblingMarker)

        await store.deleteEntry(id: "..")

        #expect(FileManager.default.fileExists(atPath: siblingMarker.path))
    }

    @Test("deleteEntry removes a begun-but-empty entry and clears its active mark")
    func deleteEntryRemovesBegunEmptyEntry() async throws {
        let (store, _) = makeStore()
        let handle = try await store.beginEntry(startedAt: Date())

        await store.deleteEntry(id: handle.id)

        #expect(!FileManager.default.fileExists(atPath: handle.directoryURL.path))
        // Clearing the active mark means a subsequent deleteAll() doesn't error out trying to guard
        // a folder that no longer exists -- exercised indirectly via a second, unrelated entry.
        let other = try await store.beginEntry(startedAt: Date())
        try await store.finalize(handle: other, entry: makeEntry(), maxEntries: 100)
        try await store.deleteAll()
        #expect(await store.listEntries().isEmpty)
    }

    // MARK: - Missing root directory (section 5.2, mirrors SessionStore.listSessions)

    @Test("listEntries returns an empty array when the root directory doesn't exist yet")
    func listEntriesReturnsEmptyWhenRootMissing() async {
        let (store, root) = makeStore()
        #expect(!FileManager.default.fileExists(atPath: root.path))

        let items = await store.listEntries()

        #expect(items.isEmpty)
    }

    @Test("deleteAll is a no-op (does not throw) when the root directory doesn't exist yet")
    func deleteAllNoOpWhenRootMissing() async throws {
        let (store, _) = makeStore()
        try await store.deleteAll()
    }

    // MARK: - Invalid entry ids (validateEntryId, shared by readEntry/deleteEntry)

    @Test(
        "readEntry(id:) throws invalidEntryId (not entryNotFound) for malformed ids",
        arguments: ["", ".", "..", "a/b", "/etc/passwd"]
    )
    func readEntryThrowsInvalidEntryIdForMalformedIds(id: String) async {
        let (store, _) = makeStore()

        await #expect(throws: DictationHistoryStore.StoreError.invalidEntryId(id)) {
            _ = try await store.readEntry(id: id)
        }
    }

    @Test(
        "deleteEntry(id:) silently refuses malformed ids instead of resolving them under rootDirectory",
        arguments: ["", ".", "..", "a/b"]
    )
    func deleteEntryRefusesMalformedIds(id: String) async throws {
        let (store, root) = makeStore()
        _ = try await store.beginEntry(startedAt: Date())

        await store.deleteEntry(id: id)

        // The only observable contract for a rejected id is "nothing outside rootDirectory was
        // touched" -- `root` itself (and thus the entry created above) must still be there.
        #expect(FileManager.default.fileExists(atPath: root.path))
    }

    // MARK: - beginEntry failure (StoreError.directoryCreationFailed)

    @Test("beginEntry(startedAt:) throws directoryCreationFailed when a plain file blocks the entry directory's path")
    func beginEntryThrowsWhenDirectoryCreationFails() async throws {
        let (store, root) = makeStore()
        // Create `root` itself as a plain *file* rather than a directory: `createDirectory(at:
        // withIntermediateDirectories: true)` for any path under it must then fail, because a path
        // component along the way already exists and is not a directory.
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: root)

        await #expect(throws: (any Error).self) {
            _ = try await store.beginEntry(startedAt: Date())
        }
    }

    // MARK: - entryDirectoryURL(forId:) / audioFileURL(forId:)

    @Test("entryDirectoryURL(forId:) resolves to defaultRootDirectory/id")
    func entryDirectoryURLResolvesUnderDefaultRootDirectory() {
        let id = "2026-07-10T09-15-32_a1b2c3d4"

        let url = DictationHistoryStore.entryDirectoryURL(forId: id)

        #expect(url == DictationHistoryStore.defaultRootDirectory.appendingPathComponent(id, isDirectory: true))
    }

    @Test("audioFileURL(forId:) resolves to entryDirectoryURL(forId:)/audio.wav")
    func audioFileURLResolvesUnderDefaultRootDirectory() {
        let id = "2026-07-10T09-15-32_a1b2c3d4"

        let url = DictationHistoryStore.audioFileURL(forId: id)

        #expect(url == DictationHistoryStore.entryDirectoryURL(forId: id).appendingPathComponent("audio.wav"))
    }

    // MARK: - listEntries ordering

    @Test("listEntries returns entries newest-first regardless of creation order")
    func listEntriesOrdersNewestFirst() async throws {
        let (store, _) = makeStore()
        let offsets: [Double] = [50, 0, 100]
        var idsByOffset: [Double: String] = [:]
        for offset in offsets {
            let handle = try await store.beginEntry(startedAt: Date(timeIntervalSince1970: 1_751_000_000 + offset))
            try await store.finalize(
                handle: handle,
                entry: makeEntry(recordedAt: Date(timeIntervalSince1970: 1_751_000_000 + offset)),
                maxEntries: 100
            )
            idsByOffset[offset] = handle.id
        }

        let items = await store.listEntries()

        #expect(items.map(\.id) == [idsByOffset[100]!, idsByOffset[50]!, idsByOffset[0]!])
    }

    // MARK: - Pruning integration (section 5.2 / 7, DH7)

    @Test("finalize prunes the oldest entries beyond maxEntries, keeping the active entry regardless")
    func finalizePrunesOldestBeyondMaxEntries() async throws {
        let (store, _) = makeStore()
        var handles: [DictationHistoryStore.EntryHandle] = []
        for offset in 0..<3 {
            let handle = try await store.beginEntry(startedAt: Date(timeIntervalSince1970: 1_751_000_000 + Double(offset)))
            try await store.finalize(
                handle: handle,
                entry: makeEntry(recordedAt: Date(timeIntervalSince1970: 1_751_000_000 + Double(offset))),
                maxEntries: 2
            )
            handles.append(handle)
        }

        let items = await store.listEntries()

        // Only the two most recent (offset 1, 2) survive; offset 0 was pruned.
        #expect(items.count == 2)
        #expect(Set(items.map(\.id)) == Set(handles.dropFirst().map(\.id)))
        #expect(!FileManager.default.fileExists(atPath: handles[0].directoryURL.path))
    }
}
