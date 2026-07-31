import Foundation
import OSLog
import Yams

// MARK: - SessionStore

/// Global registry actor: session lifecycle (create/open/list/delete) and the app-wide Recording
/// exclusivity flag. Does **not** perform the heavy per-session file I/O itself — that is
/// `SessionHandle`'s job, one actor instance per open session (design doc section 3/4).
///
/// Every config-derived value this type needs (`sessionsRootDirectory`, the default
/// context/template/watcher-list file locations) is a constructor parameter with an XDG-path
/// default, keeping `SessionStore` directly testable against a temporary directory rather than
/// reading `AppConfig.shared` itself. `static let shared` below is the one place that resolves the
/// `defaults.context_file`/`defaults.summary_template_file`/`watchers.default_enabled_file` config
/// values into `defaultContextFileURL`/`defaultSummaryTemplateFileURL`/`defaultEnabledWatchersFileURL`
/// (`docs/design/26-settings-ui.md` §4.2 / `docs/design/05-watcher-runner.md` §3.1's "残作業は config
/// 配線"); `sessionsRootDirectory` is the only default left un-config-backed (`storage.session_dir`
/// is intentionally out of Settings UI scope, `docs/design/26-settings-ui.md` §1).
actor SessionStore {
    static let shared = SessionStore(
        sessionsRootDirectory: SessionStore.defaultSessionsRootDirectory,
        defaultContextFileURL: FileManager.expandingTildePath(AppConfig.shared.data.defaults.contextFile),
        defaultSummaryTemplateFileURL: FileManager.expandingTildePath(AppConfig.shared.data.defaults.summaryTemplateFile),
        defaultEnabledWatchersFileURL: FileManager.expandingTildePath(AppConfig.shared.data.watchers.defaultEnabledFile),
        profilesDirectoryURL: FileManager.expandingTildePath(AppConfig.shared.data.profiles.dir)
    )

    // Not `private`: `SessionStore+Defaults.swift` (split out for `file_length`) reads all five
    // through its `loadInitial*(seed:profile:)` helpers, plus `logger` for their warning logs.
    let sessionsRootDirectory: URL
    let defaultContextFileURL: URL
    let defaultSummaryTemplateFileURL: URL
    let defaultEnabledWatchersFileURL: URL
    /// `~/.config/kikimi/profiles/` (`docs/design/41-meeting-profiles.md` §2.4/§3.1); DI'd for tests,
    /// only `static let shared` resolves it from `AppConfig.shared.data.profiles.dir`.
    let profilesDirectoryURL: URL
    private let metaFlushInterval: TimeInterval
    private let fileManager: FileManager
    let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "SessionStore")

    /// `SessionHandle` instances vended by `openSession(_:)`, keyed by session id. Kept alive for
    /// the lifetime of `SessionStore` (see design doc section 16 Open Questions re: cache eviction,
    /// left to `06-ui-panels.md`/`WindowManager`); a given session id always resolves to the same
    /// instance once opened.
    private var handles: [String: SessionHandle] = [:]

    private(set) var recordingSessionId: String?

    /// Live subscribers registered via `subscribeToRecordingSessionId()`, keyed by a per-subscription
    /// `UUID` so `onTermination` can remove exactly the right entry (`06-ui-panels.md` section 5.2:
    /// "stream の `onTermination` で購読者リストから自動的に取り除かれる"). Broadcasting to every
    /// continuation here is the only way to notify subscribers of a `recordingSessionId` change:
    /// `@Published`/Combine are not available inside a plain actor, and callers outside the actor
    /// (e.g. `WindowManager`, `06-ui-panels.md` section 5.2) need an `AsyncStream` they can `for
    /// await` over from any isolation context.
    private var recordingSessionIdSubscribers: [UUID: AsyncStream<String?>.Continuation] = [:]

    init(
        sessionsRootDirectory: URL,
        defaultContextFileURL: URL = SessionStore.defaultContextFileURL,
        defaultSummaryTemplateFileURL: URL = SessionStore.defaultSummaryTemplateFileURL,
        defaultEnabledWatchersFileURL: URL = SessionStore.defaultEnabledWatchersFileURL,
        profilesDirectoryURL: URL = SessionStore.defaultProfilesDirectoryURL,
        metaFlushInterval: TimeInterval = 5.0,
        fileManager: FileManager = .default
    ) {
        self.sessionsRootDirectory = sessionsRootDirectory
        self.defaultContextFileURL = defaultContextFileURL
        self.defaultSummaryTemplateFileURL = defaultSummaryTemplateFileURL
        self.defaultEnabledWatchersFileURL = defaultEnabledWatchersFileURL
        self.profilesDirectoryURL = profilesDirectoryURL
        self.metaFlushInterval = metaFlushInterval
        self.fileManager = fileManager
    }

    // MARK: Default XDG paths (kikimi.md 12 章)
    //
    // `defaultContextFileURL`/`defaultSummaryTemplateFileURL` double as `init(...)`'s parameter
    // defaults (DI for tests) *and* the values `DefaultsConfig.default`'s `contextFile`/
    // `summaryTemplateFile` strings must always tilde-expand to -- the two are meant to never drift
    // apart (`docs/design/26-settings-ui.md` §4.2).

    static var defaultSessionsRootDirectory: URL {
        FileManager.realHomeDirectory.appendingPathComponent(".local/state/kikimi/sessions", isDirectory: true)
    }

    static var defaultContextFileURL: URL {
        FileManager.realHomeDirectory.appendingPathComponent(".config/kikimi/context/common.md")
    }

    static var defaultSummaryTemplateFileURL: URL {
        FileManager.realHomeDirectory.appendingPathComponent(".config/kikimi/templates/summary.md")
    }

    static var defaultEnabledWatchersFileURL: URL {
        FileManager.realHomeDirectory.appendingPathComponent(".config/kikimi/default_watchers.yaml")
    }

    // `defaultProfilesDirectoryURL` (tilde-expanded `ProfilesConfig.default.dir`) lives in
    // `SessionStore+Defaults.swift` to keep this file under the project's `file_length` lint limit.

    /// The built-in view template used when neither a `basedOn` source session nor the global
    /// default template file (`defaults.summary_template_file`) is readable (design doc section 8,
    /// failure mode #2). Kept as an alias for `SessionHandle.defaultSummaryTemplate`
    /// (`SessionHandle+Prep.swift`) so the template string has exactly one source of truth.
    static let builtInDefaultSummaryTemplate = SessionHandle.defaultSummaryTemplate

    // MARK: Session lifecycle

    /// Creates a brand-new Draft session, seeding its prep files from `seed`
    /// (`docs/design/41-meeting-profiles.md` §3.1/§4; `.profile(id:)` resolution/fallback lives in
    /// `resolveDraftSeed(_:)`, `SessionStore+Defaults.swift`). No default: `= .none` would make a bare
    /// `createDraftSession()` ambiguous against the `createDraftSession(basedOn:)` wrapper below.
    @discardableResult
    func createDraftSession(seed: DraftSeed) async throws -> DraftCreationResult {
        if case .basedOn(let sourceSessionId) = seed {
            try SessionIdValidation.validate(sourceSessionId)
        }

        let (appliedSeed, resolvedProfile) = await resolveDraftSeed(seed)

        let now = Date()
        let id = EntryIdNaming.makeId(for: now)
        let directoryURL = sessionsRootDirectory.appendingPathComponent(id, isDirectory: true)

        // No explicit `watchers/` mkdir here: `writeEnabledWatchers(_:)` below creates any missing
        // parent directory itself (`SessionHandle.swift`'s `createParentDirectoryIfNeeded(for:)`).
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        } catch {
            logger.error("Failed to create session directory for \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw SessionStoreError.directoryCreationFailed(error.localizedDescription)
        }

        let meta = SessionMeta(
            id: id,
            title: "",
            titleAutoGenerated: true,
            titleAutoNamedOnce: false,
            titleProposal: nil,
            state: .draft,
            createdAt: now,
            startedAt: nil,
            endedAt: nil,
            durationMs: 0,
            recordings: [],
            basedOnSession: appliedSeed.basedOnSessionForMeta,
            profileId: appliedSeed.profileIdForMeta,
            segmentCount: 0,
            refinedCount: 0,
            appVersion: Self.appVersion
        )

        do {
            let handle = SessionHandle(directoryURL: directoryURL, meta: meta, metaFlushInterval: metaFlushInterval)
            // `SessionHandle.init` never touches disk itself; a no-op `updateMeta` forces the
            // immediate-write path to persist this brand-new session's `meta.json` for the first time.
            try await handle.updateMeta { _ in }
            try await handle.ensureTranscriptAndRefinedLogFilesExist()
            try await handle.writeContext(loadInitialContext(seed: seed, profile: resolvedProfile))
            try await handle.writeSummaryTemplate(loadInitialSummaryTemplate(seed: seed, profile: resolvedProfile))
            try await handle.writeEnabledWatchers(loadInitialEnabledWatchers(seed: seed, profile: resolvedProfile))
            // `nil` (no seed-provided roster) writes nothing -- see `loadInitialParticipantIds(seed:profile:)`.
            if let participantIds = loadInitialParticipantIds(seed: seed, profile: resolvedProfile) {
                try await handle.updateParticipants { $0.participantIds = participantIds }
            }
            handles[id] = handle
            return DraftCreationResult(meta: meta, appliedSeed: appliedSeed)
        } catch {
            // The directory was just created by this call; don't leave a half-initialized folder
            // behind if a later step (context/template/watcher-list write) failed.
            try? fileManager.removeItem(at: directoryURL)
            throw error
        }
    }

    // `createDraftSession(basedOn:)` (the thin `.meta`-only compatibility wrapper over
    // `createDraftSession(seed:)` above) lives in `SessionStore+Defaults.swift` alongside
    // `resolveDraftSeed(_:)`, to keep this file under the project's `file_length` lint limit.

    func openSession(_ sessionId: String) async throws -> SessionHandle {
        try SessionIdValidation.validate(sessionId)
        if let cached = handles[sessionId] {
            return cached
        }
        let directoryURL = sessionsRootDirectory.appendingPathComponent(sessionId, isDirectory: true)
        let metaURL = directoryURL.appendingPathComponent((try? SessionFile.meta.relativePath()) ?? "meta.json")
        guard fileManager.fileExists(atPath: metaURL.path) else {
            throw SessionStoreError.sessionNotFound(sessionId)
        }
        do {
            let data = try Data(contentsOf: metaURL)
            let meta = try SessionJSONCoding.makeDecoder().decode(SessionMeta.self, from: data)
            let handle = SessionHandle(directoryURL: directoryURL, meta: meta, metaFlushInterval: metaFlushInterval)
            try await handle.ensureTranscriptAndRefinedLogFilesExist()
            handles[sessionId] = handle
            return handle
        } catch {
            logger.error("Failed to open session \(sessionId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw SessionStoreError.sessionNotFound(sessionId)
        }
    }

    func listSessions() async -> [SessionMeta] {
        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(at: sessionsRootDirectory, includingPropertiesForKeys: nil)
        } catch {
            // The sessions root not existing yet (e.g. very first launch) is not an error worth
            // logging at `.error`; anything else (permissions, etc.) is.
            if (error as NSError).code != NSFileReadNoSuchFileError {
                logger.error("Failed to list the sessions root directory: \(error.localizedDescription, privacy: .public)")
            }
            return []
        }

        let decoder = SessionJSONCoding.makeDecoder()
        var results: [SessionMeta] = []
        for entry in entries {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: entry.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                continue
            }
            let metaURL = entry.appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: metaURL) else {
                logger.error("Skipping session with a missing/unreadable meta.json: \(entry.lastPathComponent, privacy: .public)")
                continue
            }
            do {
                results.append(try decoder.decode(SessionMeta.self, from: data))
            } catch {
                logger.error(
                    "Skipping session with a corrupt meta.json: \(entry.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        return results.sorted { $0.createdAt > $1.createdAt }
    }

    func deleteSession(_ sessionId: String) async throws {
        guard recordingSessionId != sessionId else {
            throw SessionStoreError.cannotDeleteActiveRecording(sessionId)
        }
        try SessionIdValidation.validate(sessionId)
        let directoryURL = sessionsRootDirectory.appendingPathComponent(sessionId, isDirectory: true)
        // Close any `transcript.jsonl`/`refined.jsonl` `FileHandle`s the process-wide
        // `AppendOnlyLogFileRegistry` (`SessionHandle+Transcript.swift`) may have cached for this
        // session *before* removing the directory, regardless of whether this `SessionStore`
        // instance ever `openSession`'d it this run — otherwise the registry entry (and the disk
        // space `removeItem` alone can't reclaim while a handle stays open) would leak for the rest
        // of this long-running menu bar app's process lifetime.
        SessionHandle.closeAppendOnlyLogFiles(inSessionDirectory: directoryURL)
        do {
            try fileManager.removeItem(at: directoryURL)
        } catch {
            logger.error("Failed to delete session \(sessionId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw SessionStoreError.directoryDeletionFailed(error.localizedDescription)
        }
        handles.removeValue(forKey: sessionId)
    }

    // MARK: Recording exclusivity (design doc section 9; kikimi.md 4 章 "「停止」と「終了」を分離する")
    //
    // Every state transition that starts a *new* recording segment (`beginRecording`/
    // `resumeRecording`/`reopenForRecording`) claims `recordingSessionId` exclusivity and opens a
    // new `RecordingSegment`; every transition that stops one (`pauseRecording`/`endMeeting`) closes
    // the currently-open segment, folds its length into `meta.durationMs`, and — only for
    // `pauseRecording`/an `endMeeting` called while `.recording` — releases the exclusivity flag
    // (kikimi.md 4 章: pausing frees the single shared audio resource, so a *different* session can
    // start recording while this one sits Paused). `cancelRecordingStart(_:revertingTo:)` is the
    // shared rollback path for all three "start a segment" transitions failing partway through
    // `TranscriptPipeline.prepare(...)`/`AudioCapture.start()` (`docs/design/06-ui-panels.md`
    // section 4/6.1) — see its own doc comment.

    /// Draft -> Recording. Opens the session's first `RecordingSegment` (`index: 0`,
    /// `startMsOffset: 0`) and sets `startedAt` (kikimi.md 5 章: "最初の録音開始時刻（不変）").
    @discardableResult
    func beginRecording(_ sessionId: String) async throws -> SessionHandle {
        if let activeId = recordingSessionId, activeId != sessionId {
            throw SessionStoreError.anotherSessionRecording(activeSessionId: activeId)
        }
        let handle = try await openSession(sessionId)
        let currentState = await handle.meta.state
        guard currentState == .draft else {
            throw SessionStoreError.sessionNotInDraftState(sessionId)
        }

        setRecordingSessionId(sessionId)
        do {
            try await handle.updateMeta { meta in
                let now = Date()
                meta.state = .recording
                meta.startedAt = now
                meta.recordings = [RecordingSegment(index: 0, startedAt: now, endedAt: nil, startMsOffset: 0)]
            }
        } catch {
            // Roll the in-memory exclusivity flag back so a write failure doesn't permanently wedge
            // recording (design doc section 12, failure mode #4).
            setRecordingSessionId(nil)
            throw error
        }
        return handle
    }

    /// Recording -> Paused. Closes the currently-open `RecordingSegment`, folds its length into
    /// `meta.durationMs`, and releases the recording-exclusivity flag (audio resources are freed;
    /// another session may now begin/resume recording). `on_session_end` never runs for a pause
    /// (kikimi.md 4 章): this is the "stop but the meeting continues" operation.
    func pauseRecording(_ sessionId: String) async throws {
        let handle = try await requireRecordingHandle(sessionId)

        try await handle.updateMeta { meta in
            Self.closeCurrentSegment(in: &meta, at: Date())
            meta.state = .paused
        }
        setRecordingSessionId(nil)
    }

    /// Paused -> Recording. Opens a new `RecordingSegment` (`index: recordings.count`,
    /// `startMsOffset: meta.durationMs`) continuing the same session's timeline (kikimi.md 6 章
    /// "録音区間ごとの STT リセットとタイムライン採番").
    @discardableResult
    func resumeRecording(_ sessionId: String) async throws -> SessionHandle {
        if let activeId = recordingSessionId, activeId != sessionId {
            throw SessionStoreError.anotherSessionRecording(activeSessionId: activeId)
        }
        let handle = try await openSession(sessionId)
        let currentState = await handle.meta.state
        guard currentState == .paused else {
            throw SessionStoreError.sessionNotInPausedState(sessionId)
        }

        setRecordingSessionId(sessionId)
        do {
            try await handle.updateMeta { meta in
                Self.openNewSegment(in: &meta, at: Date())
                meta.state = .recording
            }
        } catch {
            setRecordingSessionId(nil)
            throw error
        }
        return handle
    }

    /// Recording or Paused -> Ended: the sole confirmation operation (kikimi.md 4 章 "会議終了"). If
    /// still `.recording`, the currently-open segment is closed and its length folded into
    /// `meta.durationMs` first (matching `pauseRecording`'s close logic) and the recording-
    /// exclusivity flag is released; if already `.paused`, the flag is already released and every
    /// segment is already closed, so only `state`/`endedAt` change.
    func endMeeting(_ sessionId: String) async throws {
        let handle = try await openSession(sessionId)
        let currentState = await handle.meta.state
        guard currentState == .recording || currentState == .paused else {
            throw SessionStoreError.sessionNotRecordingOrPaused(sessionId)
        }
        if currentState == .recording {
            // Same ownership guard as `pauseRecording`'s `requireRecordingHandle`: only the session
            // actually holding the exclusivity flag may end its own in-progress recording.
            guard recordingSessionId == sessionId else {
                throw SessionStoreError.sessionNotRecordingOrPaused(sessionId)
            }
        }

        try await handle.updateMeta { meta in
            let now = Date()
            if meta.state == .recording {
                Self.closeCurrentSegment(in: &meta, at: now)
            }
            meta.state = .ended
            meta.endedAt = now
        }
        if currentState == .recording {
            setRecordingSessionId(nil)
        }
    }

    /// Ended -> Recording: the "救済パス" (kikimi.md 4 章 "Ended も可逆"). Opens a new
    /// `RecordingSegment` exactly like `resumeRecording(_:)` and clears `meta.endedAt` (kikimi.md 5
    /// 章: "Recording / Paused の間は `null`").
    @discardableResult
    func reopenForRecording(_ sessionId: String) async throws -> SessionHandle {
        if let activeId = recordingSessionId, activeId != sessionId {
            throw SessionStoreError.anotherSessionRecording(activeSessionId: activeId)
        }
        let handle = try await openSession(sessionId)
        let currentState = await handle.meta.state
        guard currentState == .ended else {
            throw SessionStoreError.sessionNotInEndedState(sessionId)
        }

        setRecordingSessionId(sessionId)
        do {
            try await handle.updateMeta { meta in
                Self.openNewSegment(in: &meta, at: Date())
                meta.state = .recording
                meta.endedAt = nil
            }
        } catch {
            setRecordingSessionId(nil)
            throw error
        }
        return handle
    }

    /// Rollback-only counterpart shared by `beginRecording(_:)`/`resumeRecording(_:)`/
    /// `reopenForRecording(_:)`, for when the segment-start sequence fails partway through
    /// `TranscriptPipeline.prepare(...)`/`AudioCapture.start()` (`docs/design/06-ui-panels.md`
    /// section 4/6.1) — reusing `pauseRecording`/`endMeeting` for this would leave a spurious
    /// near-empty Paused/Ended session behind on every failed start.
    ///
    /// Callers must only invoke this when `AudioCapture.start()` has never succeeded for this
    /// attempt (i.e. no audio bytes have been written for the segment being rolled back): it
    /// discards the just-opened `RecordingSegment` and rewinds `meta.state` to `previousState`
    /// (`.draft` for a failed `beginRecording`, `.paused` for a failed `resumeRecording`, `.ended`
    /// for a failed `reopenForRecording`) without inspecting or discarding any previously-recorded
    /// data, and does **not** remove the session folder.
    ///
    /// `previousState == .ended`'s `meta.endedAt` is restored from the now-last segment's
    /// `endedAt` — `endMeeting(_:)` always sets both to the same timestamp, so after discarding the
    /// segment `reopenForRecording(_:)` just opened, the previous segment's `endedAt` is exactly
    /// the `meta.endedAt` that was cleared.
    func cancelRecordingStart(_ sessionId: String, revertingTo previousState: SessionState) async throws {
        guard recordingSessionId == sessionId else {
            throw SessionStoreError.sessionNotInRecordingState(sessionId)
        }
        let handle = try await openSession(sessionId)

        try await handle.updateMeta { meta in
            if let last = meta.recordings.last, last.endedAt == nil {
                meta.recordings.removeLast()
            }
            meta.state = previousState
            switch previousState {
            case .draft:
                meta.startedAt = nil
            case .ended:
                meta.endedAt = meta.recordings.last?.endedAt
            case .paused, .recording:
                break
            }
        }
        setRecordingSessionId(nil)
    }

    // MARK: Recording state subscription (`docs/design/06-ui-panels.md` section 5.2)

    /// Yields the current `recordingSessionId` immediately, then a new value on every subsequent
    /// change made by `beginRecording(_:)`/`pauseRecording(_:)`/`resumeRecording(_:)`/
    /// `endMeeting(_:)`/`reopenForRecording(_:)`/`cancelRecordingStart(_:revertingTo:)`, so a caller in
    /// any isolation context can observe "current value + all changes" without a race between reading
    /// `recordingSessionId` and starting to listen. The returned stream removes itself from
    /// `recordingSessionIdSubscribers` via `onTermination` once the caller stops iterating or cancels.
    func subscribeToRecordingSessionId() -> AsyncStream<String?> {
        let initialValue = recordingSessionId
        let subscriberId = UUID()
        return AsyncStream { continuation in
            continuation.yield(initialValue)
            recordingSessionIdSubscribers[subscriberId] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeRecordingSessionIdSubscriber(subscriberId) }
            }
        }
    }

    // MARK: Crash recovery (design doc section 10)
    //
    // `detectIncompleteSessions()`/`finalizeCrashedSession(_:)` are implemented in
    // `SessionStore+CrashRecovery.swift`, not here (kept out of the primary declaration to match
    // that file's stated goal of keeping this one focused on the lifecycle/registry API).

    // MARK: All-session directory enumeration (`docs/design/16-llm-usage-stats.md` section 5)
    //
    // `readAllLLMUsageRecords()` (`SessionStore+LLMUsage.swift`) needs every session's directory
    // to read its `llm_usage.jsonl` directly, without `openSession(_:)`'s side effects (populating
    // `handles`, and `ensureTranscriptAndRefinedLogFilesExist()` creating empty
    // `transcript.jsonl`/`refined.jsonl` for every session in the Session List, most of which were
    // never opened this run). `sessionsRootDirectory`/`fileManager` stay `private`; this one small
    // accessor is exposed instead, mirroring `listSessions()`'s own directory-listing/filtering
    // logic below.
    func sessionDirectoryURLs() -> [URL] {
        guard let entries = try? fileManager.contentsOfDirectory(at: sessionsRootDirectory, includingPropertiesForKeys: nil) else {
            return []
        }
        return entries.filter { entry in
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: entry.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    // MARK: Side-effect-free read entry point (design doc section 3.2(b))
    //
    // `readOnlySessionHandle(_:)` needs to hand back a `SessionHandle` to callers that only want to
    // read a session (not `openSession(_:)`'s side effects: populating `handles` for the lifetime of
    // this process, and `ensureTranscriptAndRefinedLogFilesExist()` creating empty
    // `transcript.jsonl`/`refined.jsonl` for a session that was never actually opened this run —
    // see `SessionStore+LLMUsage.swift`'s `readAllLLMUsageRecords()` doc comment for the same
    // rationale). If the session is already open (recording or otherwise), the cached handle must be
    // reused instead of building a second one: a second handle reading `transcript.jsonl` would race
    // the cached handle's own serialized JSONL appends and could observe a partially-written line.

    /// Returns a `SessionHandle` for `sessionId` without any of `openSession(_:)`'s side effects.
    /// If `sessionId` already has a cached handle (from a prior `openSession(_:)` call — most
    /// notably the currently-recording session), that cached handle is returned as-is so reads stay
    /// serialized with the handle's in-flight JSONL appends and never observe a partially-written
    /// line. Otherwise this reads `sessionsRootDirectory/{sessionId}/meta.json` directly and builds
    /// a fresh `SessionHandle` from it, *without* registering it in `handles` or calling
    /// `ensureTranscriptAndRefinedLogFilesExist()` — the handle is meant to be read from and
    /// discarded. Returns `nil` (logging at `.error`) if `sessionId` fails `SessionIdValidation`,
    /// the session directory or `meta.json` does not exist, or `meta.json` fails to decode.
    func readOnlySessionHandle(_ sessionId: String) async -> SessionHandle? {
        do {
            try SessionIdValidation.validate(sessionId)
        } catch {
            logger.error("Rejected invalid session id for read-only access \(sessionId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }

        if let cached = handles[sessionId] {
            return cached
        }

        let directoryURL = sessionsRootDirectory.appendingPathComponent(sessionId, isDirectory: true)
        let metaURL = directoryURL.appendingPathComponent((try? SessionFile.meta.relativePath()) ?? "meta.json")
        guard fileManager.fileExists(atPath: metaURL.path) else {
            logger.error("No meta.json found for read-only session access \(sessionId, privacy: .public)")
            return nil
        }
        do {
            let data = try Data(contentsOf: metaURL)
            let meta = try SessionJSONCoding.makeDecoder().decode(SessionMeta.self, from: data)
            return SessionHandle(directoryURL: directoryURL, meta: meta, metaFlushInterval: metaFlushInterval)
        } catch {
            logger.error("Failed to read session \(sessionId, privacy: .public) for read-only access: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: Private helpers

    /// Shared precondition for `pauseRecording(_:)`: requires that `sessionId` is the
    /// currently-recording session (not just any `.recording`-state session, which guards against a
    /// stale/duplicate caller racing the actual owner) and that its persisted `meta.state` still
    /// agrees.
    private func requireRecordingHandle(_ sessionId: String) async throws -> SessionHandle {
        guard recordingSessionId == sessionId else {
            throw SessionStoreError.sessionNotInRecordingState(sessionId)
        }
        let handle = try await openSession(sessionId)
        let currentState = await handle.meta.state
        guard currentState == .recording else {
            throw SessionStoreError.sessionNotInRecordingState(sessionId)
        }
        return handle
    }

    /// Closes `meta`'s currently-open `RecordingSegment` (if any) at `now`, folding its length into
    /// `meta.durationMs`. Shared by `pauseRecording(_:)` and `endMeeting(_:)`'s `.recording` branch
    /// — both "stop capturing audio" transitions close the segment identically. A no-op if there is
    /// no open segment (defensive; every `.recording` session is expected to have exactly one).
    private static func closeCurrentSegment(in meta: inout SessionMeta, at now: Date) {
        guard var last = meta.recordings.last, last.endedAt == nil else { return }
        last.endedAt = now
        meta.recordings[meta.recordings.count - 1] = last
        let segmentDurationMs = Int(now.timeIntervalSince(last.startedAt) * 1_000)
        meta.durationMs += max(0, segmentDurationMs)
    }

    /// Appends a new open `RecordingSegment` to `meta.recordings`, starting at `now` and offset by
    /// `meta.durationMs` (the cumulative length of every already-closed segment). Shared by
    /// `resumeRecording(_:)` and `reopenForRecording(_:)` — both "start capturing audio again"
    /// transitions open a segment identically.
    private static func openNewSegment(in meta: inout SessionMeta, at now: Date) {
        let newIndex = meta.recordings.count
        meta.recordings.append(RecordingSegment(index: newIndex, startedAt: now, endedAt: nil, startMsOffset: meta.durationMs))
    }

    /// Single choke point for mutating `recordingSessionId`: every write goes through here so a
    /// broadcast to `recordingSessionIdSubscribers` can never be forgotten at a call site.
    private func setRecordingSessionId(_ sessionId: String?) {
        recordingSessionId = sessionId
        for continuation in recordingSessionIdSubscribers.values {
            continuation.yield(sessionId)
        }
    }

    private func removeRecordingSessionIdSubscriber(_ subscriberId: UUID) {
        recordingSessionIdSubscribers.removeValue(forKey: subscriberId)
    }

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

}

// `createDraftSession(seed:)`'s default-resolution helpers (`loadInitialContext(seed:profile:)` etc.,
// `resolveDraftSeed(_:)`) and its `createDraftSession(basedOn:)` compatibility wrapper live in
// `SessionStore+Defaults.swift` to keep this file under the project's `file_length` lint limit.
