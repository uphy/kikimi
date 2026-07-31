import Combine
import Foundation
import OSLog
import os

// MARK: - PromptStore

/// Reads, watches, and writes `~/.config/kikimi/prompts/` (`docs/design/42-prompt-overrides.md` §4.1/
/// §5.1). The single runtime source of truth for "what is the currently-effective policy-layer body
/// for prompt X": `RefinementQueue`/`SummaryUpdater`/`ChatRunner`/`WatcherRunner`/`DictationController`
/// all resolve their system-prompt policy layer through `policyBody(for:)` (directly, or through a
/// provider closure a `MeetingWorkspaceViewModel+Factories.swift` factory snapshots once at session
/// start for `session-start`-reload prompts, §4.3), and `DictationAppContextSection` reads/writes
/// through this type's `@Published`-free `ObservableObject` conformance.
///
/// Reads (`policyBody(for:)`/`overrideState(for:)`/`dictationAppBundleIDs()`) are `nonisolated`: they
/// return values copied out of an `OSAllocatedUnfairLock`-protected, wholesale-replaced snapshot, so
/// they are safe to call from any isolation domain -- including plain `actor`s (`SummaryUpdater`) that
/// call `promptBodyProvider(.summary)` synchronously with no `await` (§4.3's DI shape). Every *write*
/// to that snapshot -- the initial scan, a watch-triggered rescan, `writeOverride`/`removeOverride`'s
/// own file I/O, `refreshIfStale()`'s safety-net rescan, and the `objectWillChange`/`changes`
/// notifications that follow -- is confined to the main queue (mirrors `YAMLStore`'s own
/// `DispatchQueue.main`-only mutation discipline for its `FileWatcher`-triggered reloads): `init`'s
/// own first scan runs synchronously on whatever thread constructs the store (§6.1's headless CLI
/// constructs a fresh `PromptStore(directory:)` directly, off the main thread, and expects
/// `policyBody`/`overrideState` to already reflect disk state the instant `init` returns -- so that
/// first scan cannot be deferred to a `DispatchQueue.main.async` hop the way later, watch-triggered
/// rescans are); every subsequent rescan (`writeOverride`/`removeOverride`/`refreshIfStale`'s callers,
/// and every `FileWatcher` callback) runs on the main queue, so the `@unchecked Sendable` this type
/// declares is safe by construction rather than by the compiler's proof.
final class PromptStore: ObservableObject, @unchecked Sendable {
    private static let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "PromptStore")

    /// `~/.config/kikimi/prompts/` (`docs/design/42-prompt-overrides.md` §3.1), computed the same way
    /// every other Kikimi default directory is (`FileManager.realHomeDirectory`). config.yaml gets no
    /// `prompts.dir` key (§3.1: "XDG ライク規則に固定") -- only `init(directory:)`'s parameter (tests,
    /// `--prompts-dir`) can move this.
    static let defaultPromptsDirectory = FileManager.realHomeDirectory
        .appendingPathComponent(".config/kikimi/prompts", isDirectory: true)

    /// The GUI singleton every production call site defaults to. Unlike `init(directory:)` itself
    /// (used directly by `PromptCLI` and every test, neither of which may touch `AppConfig`/`AppState`,
    /// `Kikimi/Prompts/PromptCLI.swift`'s doc comment), this lazily-computed static first mkdir -p's
    /// the 3-level layout, then runs `DictationPromptMigration.migrateIfNeeded` against it -- *before*
    /// constructing the `PromptStore` instance whose own `init` performs the first directory scan --
    /// so a freshly-migrated `prompts/dictation.md` is present on disk by the time that first scan
    /// runs and is picked up immediately rather than waiting for a subsequent watch-triggered rescan
    /// (`DictationPromptMigration`'s own doc comment: "before that store's own directory scan").
    /// `init(directory:)` below mkdir's the same layout again on construction -- harmless and
    /// idempotent, kept there so every other caller of the designated initializer (CLI, tests) still
    /// gets §5.1's "3 階層とも mkdir-p" guarantee without depending on this property ever having run.
    static let shared: PromptStore = {
        let directory = defaultPromptsDirectory
        let dictationAppsDirectory = directory.appendingPathComponent("dictation/apps", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dictationAppsDirectory, withIntermediateDirectories: true)
        } catch {
            PromptStore.logger.warning(
                "Failed to create \(directory.path, privacy: .public) ahead of dictation-prompt migration; falling back to built-in defaults: \(String(describing: error), privacy: .public)"
            )
        }
        DictationPromptMigration.migrateIfNeeded(
            dictationContext: AppConfig.shared.data.dictation.context,
            promptsDirectory: directory
        )
        return PromptStore(directory: directory)
    }()

    // MARK: - Directory layout (§3.1)

    let directory: URL
    private let dictationDirectory: URL
    private let dictationAppsDirectory: URL

    // MARK: - Snapshot (nonisolated reads, §4.1)

    /// An immutable, wholesale-replaced view of every candidate `PromptRef`'s resolved state --
    /// "wholesale-replaced" so a `nonisolated` reader taking the lock mid-rescan never observes a
    /// half-updated dictionary (the alternative, mutating a shared dictionary key by key under the
    /// lock, would need the lock held for the whole rescan instead of just the swap).
    private struct Snapshot: Sendable {
        var states: [PromptRef: PromptOverrideState] = [:]
        /// `prompts/dictation/apps/*.md` file name stems, sorted (`dictationAppBundleIDs()`'s
        /// contract) -- every currently-registered per-app override, valid or `.invalid`, since the
        /// Settings UI (`DictationAppContextSection`) still needs to list (and offer to fix/delete) a
        /// broken per-app file.
        var dictationAppBundleIDs: [String] = []
    }
    private let snapshotStorage = OSAllocatedUnfairLock(initialState: Snapshot())

    // MARK: - Watch machinery (main-queue-only; see this type's doc comment)

    private struct FileFingerprint: Equatable {
        var exists: Bool
        var modificationDate: Date?
        var size: Int?
    }
    /// `refreshIfStale()`'s (存在, mtime, size) baseline, keyed by absolute path (§5.1's safety net).
    /// Replaced wholesale at the end of every `rescan()` for exactly the candidate set that scan just
    /// resolved -- an id whose file disappeared between two rescans is naturally dropped rather than
    /// left stale.
    private var lastFingerprints: [String: FileFingerprint] = [:]
    /// One `FileWatcher` per *currently existing* override file (§5.1's per-file layer), keyed by
    /// `PromptRef.relativePath`. Re-armed at the end of every `rescan()` to match disk reality.
    private var perFileWatchers: [String: FileWatcher] = [:]
    /// The 3 fixed directory-level watchers (§5.1: `prompts/`, `prompts/dictation/`,
    /// `prompts/dictation/apps/`), installed once and never re-armed -- unlike `perFileWatchers`, the
    /// watched paths never change over this store's lifetime.
    private var directoryWatchers: [FileWatcher] = []
    private var debounceWorkItem: DispatchWorkItem?

    // MARK: - `changes` (§4.1)

    private let changesStream: AsyncStream<PromptRef>
    private let changesContinuation: AsyncStream<PromptRef>.Continuation

    /// Yields a `PromptRef` every time a rescan resolves a *different* `PromptOverrideState` for it
    /// than the previous scan held (including `.none` <-> `.active`/`.invalid` transitions from a
    /// file being created/removed). `nonisolated` because the underlying `AsyncStream` value itself is
    /// immutable and `Sendable` once set at `init` (mirrors `WatcherRunner.events`/
    /// `SummaryUpdater.events`) -- only *yielding into* it is main-queue-confined.
    nonisolated var changes: AsyncStream<PromptRef> { changesStream }

    // MARK: - Init (§5.1)

    /// - Parameter directory: The `prompts/` root. Defaults to `defaultPromptsDirectory`; tests and
    ///   `PromptCLI` (`--prompts-dir`) pass a different directory so the real
    ///   `~/.config/kikimi/prompts/` is never touched (same DI pattern as `AppConfig.init(directory:)`
    ///   /`AppState.init(directory:)`). Deliberately does **not** run `DictationPromptMigration` --
    ///   that is `.shared`'s job alone (see its doc comment) -- so this initializer never touches
    ///   `AppConfig`/`AppState`, which `PromptCLI`'s headless launch path requires.
    ///
    ///   Performs the first directory scan synchronously before returning, so `policyBody(for:)`/
    ///   `overrideState(for:)`/`dictationAppBundleIDs()` already reflect disk state the instant this
    ///   initializer returns (`PromptCLI.runList`/`runRender` construct a fresh store and read from it
    ///   immediately, with no chance to `await` a deferred scan).
    init(directory: URL = PromptStore.defaultPromptsDirectory) {
        self.directory = directory
        self.dictationDirectory = directory.appendingPathComponent("dictation", isDirectory: true)
        self.dictationAppsDirectory = dictationDirectory.appendingPathComponent("apps", isDirectory: true)
        (changesStream, changesContinuation) = AsyncStream.makeStream()

        ensureDirectoriesExist()
        rescan()
        installDirectoryWatchers()
    }

    // MARK: - Reads (nonisolated, §4.1)

    nonisolated func overrideState(for ref: PromptRef) -> PromptOverrideState {
        snapshotStorage.withLock { $0.states[ref] ?? .none }
    }

    /// The current override body if `overrideState(for: ref)` is `.active`, else `PromptSpec
    /// .defaultBody` for a `.builtin` ref or `""` for a `.dictationApp` ref (§4.1: "dictationApp は
    /// 空文字" -- there is no built-in default to fall back to for a per-app addition).
    nonisolated func policyBody(for ref: PromptRef) -> String {
        switch overrideState(for: ref) {
        case .active(let body, _):
            return body
        case .none, .invalid:
            switch ref {
            case .builtin(let id):
                return PromptSpec.spec(for: id).defaultBody
            case .dictationApp:
                return ""
            }
        }
    }

    /// `prompts/dictation/apps/*.md` file name stems, sorted (§4.1). Every currently-registered
    /// per-app override -- `.active` or `.invalid` alike -- so a broken per-app file still shows up
    /// for the Settings UI to fix or delete rather than silently vanishing from the list.
    nonisolated func dictationAppBundleIDs() -> [String] {
        snapshotStorage.withLock { $0.dictationAppBundleIDs }
    }

    // MARK: - Writes (@MainActor, §4.1)

    /// Writes `body` as `ref`'s override file, replacing any existing one, and rescans synchronously
    /// so `policyBody(for: ref)` reflects the new body the instant this call returns (a caller like
    /// `DictationAppContextSection`'s live-binding `TextEditor` cannot wait for a debounced
    /// watch-triggered rescan to see its own write take effect).
    ///
    /// - Throws: `PromptFileError.emptyBody` when `body` (trimmed) is empty and `ref` is not one of
    ///   the dictation family (`.builtin(.dictation)` / `.dictationApp`) -- §3.2/§7.3's "空本文は
    ///   dictation 系のみ許可。それ以外は throw" (a defensive rule: there is currently no UI write path
    ///   for any other id, but this keeps it that way even if one is added later). Also rethrows any
    ///   `FileManager`/`String.write` I/O error.
    @MainActor
    func writeOverride(_ ref: PromptRef, body: String) throws {
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedBody.isEmpty, !Self.allowsEmptyBodyWrite(ref) {
            throw PromptFileError.emptyBody
        }

        let url = directory.appendingPathComponent(ref.relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let text: String
        switch ref {
        case .builtin(let id):
            text = PromptFile.render(id: id.rawValue, spec: PromptSpec.spec(for: id), body: body)
        case .dictationApp(let bundleID):
            text = PromptFile.renderDictationApp(
                bundleID: bundleID,
                comment: "Per-app dictation context (追加指示) for bundle_id: \(bundleID). There is no "
                    + "built-in default for this file -- delete it to remove the addition entirely.",
                body: body
            )
        }

        try text.write(to: url, atomically: true, encoding: .utf8)
        rescan()
    }

    /// Deletes `ref`'s override file, restoring the built-in default (`.builtin`) or "no per-app
    /// addition" (`.dictationApp`). A no-op (not an error) when no override file exists -- callers
    /// like the Settings "既定に戻す" button should be able to call this idempotently.
    @MainActor
    func removeOverride(_ ref: PromptRef) throws {
        let url = directory.appendingPathComponent(ref.relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
        rescan()
    }

    /// §5.1's session-start safety net: compares every candidate path's (存在, mtime, size)
    /// fingerprint against the baseline `rescan()` last recorded, and only re-scans (synchronously) if
    /// something drifted. Callers that snapshot a `session-start`-reload prompt at the top of a new
    /// session (`defaultRefinementQueueFactory`/`defaultWatcherRunnerFactory`) call this immediately
    /// before reading, so a watch event the filesystem coalesced or this process otherwise missed can
    /// never leave a session's snapshot older than what is actually on disk.
    @MainActor
    func refreshIfStale() {
        let bundleIDs = snapshotStorage.withLock { $0.dictationAppBundleIDs }
        let isStale = candidateURLs(dictationAppBundleIDs: bundleIDs).contains { url in
            fingerprint(of: url) != (lastFingerprints[url.path] ?? FileFingerprint(exists: false, modificationDate: nil, size: nil))
        }
        if isStale {
            rescan()
        }
    }

    // MARK: - `writeOverride` helpers

    private static func allowsEmptyBodyWrite(_ ref: PromptRef) -> Bool {
        switch ref {
        case .builtin(.dictation):
            return true
        case .dictationApp:
            return true
        case .builtin:
            return false
        }
    }

    /// Re-creates the 3-level `prompts/`/`prompts/dictation/`/`prompts/dictation/apps/` layout,
    /// idempotently, at the start of every `rescan()` -- not just at `init` (§5.1: "サブディレクトリが
    /// 後から現れて watch が張れていない」状態は起きない（万一 `dictation/apps/` が手で消されたら、
    /// 親ディレクトリのイベント → 再走査で mkdir + watcher を再アームする）", §8 #12). Without this, a
    /// directory deleted out from under a running store's watchers would never come back until the next
    /// app launch, contradicting `installDirectoryWatchers()`'s own doc comment (its retry-until-reopen
    /// loop only succeeds once *something* recreates the directory). Cheap and side-effect-free when the
    /// layout already exists (`withIntermediateDirectories: true` is a no-op then).
    private func ensureDirectoriesExist() {
        do {
            try FileManager.default.createDirectory(at: dictationAppsDirectory, withIntermediateDirectories: true)
        } catch {
            // §8 #1: mkdir failure is a warning, not fatal -- every ref simply resolves to `.none`
            // (no file found under a directory that doesn't exist), so every prompt falls back to its
            // built-in default and recording/refinement is never blocked.
            Self.logger.warning(
                "Failed to (re-)create prompts directories under \(self.directory.path, privacy: .public): \(String(describing: error), privacy: .public). Every prompt will use its built-in default."
            )
        }
    }

    // MARK: - Rescan (main-queue-only)

    /// The single re-entrant point every watch event, `writeOverride`/`removeOverride`, and
    /// `refreshIfStale()` funnel through: lists disk, resolves every candidate `PromptRef`'s state,
    /// diffs against the previous snapshot (for `.invalid`/clamp warning dedup, `changes`, and
    /// `objectWillChange`), commits the new snapshot, and re-arms the per-file watcher set.
    private func rescan() {
        ensureDirectoriesExist()

        let oldSnapshot = snapshotStorage.withLock { $0 }

        let bundleIDs = discoverDictationAppBundleIDs()
        logUnrecognizedTopLevelFiles()

        let allRefs: [PromptRef] = PromptID.allCases.map(PromptRef.builtin) + bundleIDs.map { .dictationApp(bundleID: $0) }

        var newStates: [PromptRef: PromptOverrideState] = [:]
        var existingFiles: [String: URL] = [:]
        var anyChanged = false

        for ref in allRefs {
            let url = directory.appendingPathComponent(ref.relativePath)
            let (state, wasClamped) = resolveState(ref: ref, url: url)
            newStates[ref] = state
            if state != .none {
                existingFiles[ref.relativePath] = url
            }

            let oldState = oldSnapshot.states[ref] ?? .none
            guard state != oldState else { continue }
            anyChanged = true
            changesContinuation.yield(ref)
            logTransition(ref: ref, to: state, wasClamped: wasClamped)
        }

        snapshotStorage.withLock { $0 = Snapshot(states: newStates, dictationAppBundleIDs: bundleIDs) }
        if anyChanged {
            objectWillChange.send()
        }

        syncPerFileWatchers(to: existingFiles)
        lastFingerprints = Dictionary(
            uniqueKeysWithValues: candidateURLs(dictationAppBundleIDs: bundleIDs).map { ($0.path, fingerprint(of: $0)) }
        )
    }

    /// Only logs on an actual state transition (never re-logs an unchanged `.invalid`/clamped
    /// `.active`), which is what makes §5.1's "invalid への遷移時に 1 回だけ warning ログを出す" hold: a
    /// rescan triggered by some *other* ref's file changing re-resolves this ref to the exact same
    /// value, so `rescan()`'s `state != oldState` guard above never calls this again for it.
    private func logTransition(ref: PromptRef, to state: PromptOverrideState, wasClamped: Bool) {
        switch state {
        case .invalid(let error):
            Self.logger.warning(
                "Prompt override \(String(describing: ref), privacy: .public) is invalid, falling back to the built-in default: \(error.localizedDescription, privacy: .public)"
            )
        case .active where wasClamped:
            Self.logger.warning(
                "Prompt override \(String(describing: ref), privacy: .public) exceeded \(PromptFile.maxBodyBytes) bytes and was clamped."
            )
        case .active, .none:
            break
        }
    }

    /// Reads and parses `ref`'s file at `url`, or `.none` if it doesn't exist. Reading itself is the
    /// only place `PromptFileError.fileNotUTF8` can be produced (§8 #2) -- `PromptFile.parse` only
    /// ever receives an already-decoded `String`, so that failure mode belongs to this I/O boundary,
    /// not to `PromptFile` (which stays pure/no-I/O by design).
    private func resolveState(ref: PromptRef, url: URL) -> (state: PromptOverrideState, wasClamped: Bool) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (.none, false) }
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            return (.invalid(.fileNotUTF8), false)
        }

        let expectedID: String
        let spec: PromptSpec?
        switch ref {
        case .builtin(let id):
            expectedID = id.rawValue
            spec = PromptSpec.spec(for: id)
        case .dictationApp(let bundleID):
            expectedID = "dictation/apps/\(bundleID)"
            spec = nil
        }

        switch PromptFile.parse(text: text, expectedID: expectedID, spec: spec) {
        case .success(let parsed):
            return (.active(body: parsed.body, basedOn: parsed.basedOn), parsed.wasClamped)
        case .failure(let error):
            return (.invalid(error), false)
        }
    }

    /// `prompts/dictation/apps/*.md` file name stems that satisfy `PromptRef.isValidBundleID(_:)`,
    /// sorted (§3.1). Anything else (non-`.md`, or a `.md` file whose stem fails the bundle-id
    /// character class) is ignored with a debug/warning log rather than surfaced as a `PromptRef` --
    /// there is no id to resolve it against.
    private func discoverDictationAppBundleIDs() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dictationAppsDirectory.path)) ?? []
        var bundleIDs: [String] = []
        for name in names.sorted() {
            guard name.hasSuffix(".md") else {
                if !name.hasPrefix(".") {
                    Self.logger.debug("Ignoring non-.md file in prompts/dictation/apps/: \(name, privacy: .public)")
                }
                continue
            }
            let bundleID = String(name.dropLast(3))
            guard PromptRef.isValidBundleID(bundleID) else {
                Self.logger.warning("Ignoring prompts/dictation/apps/ file with an invalid bundle id: \(name, privacy: .public)")
                continue
            }
            bundleIDs.append(bundleID)
        }
        return bundleIDs
    }

    /// §3.1: "`.md` 以外・上記一覧に無いファイル名は無視して debug ログ" -- for stray files directly under
    /// `prompts/` (not `prompts/dictation/apps/`, which `discoverDictationAppBundleIDs()` already
    /// covers). Discovery only; does not affect resolved state.
    private func logUnrecognizedTopLevelFiles() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let knownStems = Set(PromptID.allCases.map(\.rawValue))
        for name in names where name.hasSuffix(".md") {
            let stem = String(name.dropLast(3))
            guard !knownStems.contains(stem) else { continue }
            Self.logger.debug("Ignoring unrecognized file under prompts/: \(name, privacy: .public)")
        }
    }

    // MARK: - Watchers (§5.1's 2-layer scheme)

    /// Installed once at `init`, never re-armed: these 3 paths are fixed for this store's lifetime
    /// (unlike `perFileWatchers`, whose keys change as override files come and go). Reusing the plain
    /// `FileWatcher` built for *files* against a *directory* works because both rely on the same
    /// `DispatchSource.makeFileSystemObjectSource` `.write` event, which kqueue also fires for a
    /// directory's own fd whenever an entry inside it is created/removed/renamed -- exactly the
    /// "ファイル集合の変化" this layer is responsible for (§5.1). If one of these directories is itself
    /// deleted out from under its watcher (e.g. `rm -rf prompts/dictation/apps`), `FileWatcher`'s own
    /// delete/rename-triggered reopen-with-retry loop keeps trying to reopen it every 0.5s; once the
    /// next rescan's `mkdir -p` (triggered by the *parent* directory's own `.write` event) recreates
    /// it, the retry succeeds and this watcher rearms itself with no help needed from here.
    private func installDirectoryWatchers() {
        directoryWatchers = [directory, dictationDirectory, dictationAppsDirectory].map { url in
            FileWatcher(url: url) { [weak self] in
                DispatchQueue.main.async { self?.scheduleRescan() }
            }
        }
    }

    /// Re-arms `perFileWatchers` to match `existingFiles` exactly: drops watchers for files `rescan()`
    /// just found gone, adds one for every file it found that isn't watched yet (§5.1's per-file
    /// layer -- catches in-place overwrites, which a directory fd's `.write` event never fires for).
    private func syncPerFileWatchers(to existingFiles: [String: URL]) {
        for key in perFileWatchers.keys where existingFiles[key] == nil {
            perFileWatchers.removeValue(forKey: key)
        }
        for (key, url) in existingFiles where perFileWatchers[key] == nil {
            perFileWatchers[key] = FileWatcher(url: url) { [weak self] in
                DispatchQueue.main.async { self?.scheduleRescan() }
            }
        }
    }

    /// §5.1: "どちらのイベントでも debounce 500ms 後に全再走査". Every directory/per-file watcher funnels
    /// here instead of calling `rescan()` directly, so a burst of events (e.g. an editor's
    /// save-as-multiple-writes) collapses into one rescan.
    private func scheduleRescan() {
        debounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.rescan() }
        debounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    // MARK: - `refreshIfStale()` helpers

    /// Every path `refreshIfStale()`/`rescan()`'s fingerprinting cares about: the 2 directories whose
    /// own mtime changes when a child is created/removed/renamed (catches a brand-new
    /// `dictation/apps/*.md` file `refreshIfStale()` hasn't seen yet), plus every currently-candidate
    /// `PromptRef`'s file (7 builtin ids, always checked regardless of whether they currently exist,
    /// plus `dictationAppBundleIDs` -- §5.1's "高々 10 数回の stat").
    private func candidateURLs(dictationAppBundleIDs: [String]) -> [URL] {
        var urls = PromptID.allCases.map { directory.appendingPathComponent(PromptRef.builtin($0).relativePath) }
        urls += dictationAppBundleIDs.map { directory.appendingPathComponent(PromptRef.dictationApp(bundleID: $0).relativePath) }
        urls.append(directory)
        urls.append(dictationAppsDirectory)
        return urls
    }

    private func fingerprint(of url: URL) -> FileFingerprint {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return FileFingerprint(exists: false, modificationDate: nil, size: nil)
        }
        return FileFingerprint(
            exists: true,
            modificationDate: attributes[.modificationDate] as? Date,
            size: attributes[.size] as? Int
        )
    }
}
