import Foundation

// MARK: - SessionState

/// Lifecycle state of a meeting session (see `docs/design/07-session-store.md` section 6 and
/// kikimi.md 4 章 "セッションウィンドウ"). Persisted as `meta.json`'s `state` field.
enum SessionState: String, Codable, Sendable {
    case draft
    case recording
    /// Recording is stopped but the meeting is not confirmed done: audio capture/STT resources are
    /// released, `on_session_end` has not run, and the session can be resumed (a new recording
    /// segment opens) or ended at any time (kikimi.md 4 章 "「停止」と「終了」を分離する").
    case paused
    case ended
}

// MARK: - SessionStoreError

/// Failure modes surfaced by `SessionStore`/`SessionHandle`. See
/// `docs/design/07-session-store.md` section 12 ("失敗モード一覧") for the full table this
/// type's cases and `errorDescription` strings are derived from.
enum SessionStoreError: LocalizedError, Equatable, Sendable {
    /// `openSession(_:)` (or any lookup) targeted a session folder that does not exist
    /// (failure mode #11).
    case sessionNotFound(String)
    /// Already a different session is Recording (kikimi.md 10 章 "Recording は同時に1つだけ",
    /// failure mode #3).
    case anotherSessionRecording(activeSessionId: String)
    /// `beginRecording(_:)` was called on a session that is not currently Draft.
    case sessionNotInDraftState(String)
    /// `pauseRecording(_:)` (or the recording-side of `cancelRecordingStart(_:revertingTo:)`) was
    /// called on a session that is not currently Recording, or `finalizeCrashedSession(_:)` was
    /// called on a session that is not `.recording`.
    case sessionNotInRecordingState(String)
    /// `resumeRecording(_:)` was called on a session that is not currently Paused.
    case sessionNotInPausedState(String)
    /// `endMeeting(_:)` was called on a session that is neither Recording nor Paused.
    case sessionNotRecordingOrPaused(String)
    /// `reopenForRecording(_:)` was called on a session that is not currently Ended.
    case sessionNotInEndedState(String)
    /// `createDraftSession()` could not create the session root directory
    /// (permissions/disk full, failure mode #1).
    case directoryCreationFailed(String)
    /// `deleteSession(_:)` could not remove the session directory
    /// (e.g. another process has a file open, failure mode #10).
    case directoryDeletionFailed(String)
    /// `deleteSession(_:)` targeted the currently Recording session (failure mode #9).
    case cannotDeleteActiveRecording(String)
    /// A caller-supplied session id was not a single, safe path component (e.g. contained "/" or
    /// was ".."/"."), which `URL.appendingPathComponent` does not reject or normalize and would
    /// otherwise resolve outside `sessionsRootDirectory` (path traversal).
    case invalidSessionId(String)

    var errorDescription: String? {
        switch self {
        case .sessionNotFound(let sessionId):
            return "Session not found: \(sessionId)"
        case .anotherSessionRecording(let activeSessionId):
            return "Another session is already recording: \(activeSessionId)"
        case .sessionNotInDraftState(let sessionId):
            return "Session is not in draft state: \(sessionId)"
        case .sessionNotInRecordingState(let sessionId):
            return "Session is not in recording state: \(sessionId)"
        case .sessionNotInPausedState(let sessionId):
            return "Session is not in paused state: \(sessionId)"
        case .sessionNotRecordingOrPaused(let sessionId):
            return "Session is neither recording nor paused: \(sessionId)"
        case .sessionNotInEndedState(let sessionId):
            return "Session is not in ended state: \(sessionId)"
        case .directoryCreationFailed(let message):
            return "Failed to create the session directory: \(message)"
        case .directoryDeletionFailed(let message):
            return "Failed to delete the session directory: \(message)"
        case .cannotDeleteActiveRecording(let sessionId):
            return "Cannot delete a session that is currently recording: \(sessionId)"
        case .invalidSessionId(let sessionId):
            return "Invalid session id: \(sessionId)"
        }
    }
}

// MARK: - SessionIdValidation

/// Rejects session ids that are anything other than a single, safe path component when resolved
/// under `sessionsRootDirectory`. Every call site that takes a session id from outside this module
/// (`SessionStore.openSession(_:)`/`deleteSession(_:)`/`createDraftSession(basedOn:)`,
/// `SessionHandle.copyPrepFiles(from:scope:)`) validates through this first — session ids that
/// `SessionStore` generates itself (`EntryIdNaming.makeId(for:)`) always pass, but ids arriving from the UI
/// (Session List selections) or the `kikimi://window/new?based_on=<session-id>` Raycast entry point
/// kikimi.md 10 章 documents are untrusted. Mirrors `SessionFile`'s watcher id validation
/// (`SessionFile.swift`) for the same underlying reason: `URL.appendingPathComponent` does not
/// normalize `..`, so an unchecked id like `"../../etc"` would resolve outside the sessions root.
enum SessionIdValidation {
    static func validate(_ sessionId: String) throws {
        guard !sessionId.isEmpty, sessionId != ".", sessionId != "..", !sessionId.contains("/") else {
            throw SessionStoreError.invalidSessionId(sessionId)
        }
    }
}

// MARK: - DraftSeed

/// What seeds a new Draft session's prep files (context.md / summary_template.md / enabled
/// watchers / participants), passed to `SessionStore.createDraftSession(seed:)`
/// (`docs/design/41-meeting-profiles.md` §3.1). Exactly one source applies; the per-file fallback
/// chain for each (source -> global default -> built-in) is documented on each
/// `SessionStore+Defaults.swift` `loadInitial*(seed:profile:)` helper and design doc §4's table.
enum DraftSeed: Equatable, Sendable {
    /// Global defaults only (the existing "+ 新規" path).
    case none
    /// Copy from an existing session (the existing "複製して新規" path).
    case basedOn(sessionId: String)
    /// Copy from a saved meeting profile.
    case profile(id: String)
}

// MARK: - AppliedDraftSeed

/// What `SessionStore.createDraftSession(seed:)` actually applied (`docs/design/
/// 41-meeting-profiles.md` §3.1). Mirrors `DraftSeed` case-for-case, plus `.profileFallback` for the
/// one case where the requested seed could not be honored as-is. `.profileFallback` is how the soft
/// fallback (§4 / §8 failure mode #3) travels back to the caller **as data**: `SessionStore` never
/// touches any UI surface (no toast, no banner) -- presentation of that fallback is
/// `WindowManager`'s job (§3.3 / §6.5), driven entirely off this value.
enum AppliedDraftSeed: Equatable, Sendable {
    case none
    case basedOn(sessionId: String)
    case profile(id: String)
    /// `.profile(id: requestedId)` was requested but could not be resolved (invalid id / directory
    /// missing / broken `profile.yaml`, §8 #3): the session was still created, seeded with global
    /// defaults exactly as `.none` would be, and `meta.profileId` was **not** recorded.
    case profileFallback(requestedId: String)
}

extension AppliedDraftSeed {
    /// `SessionMeta.basedOnSession` to record for this applied seed: non-nil only for `.basedOn`.
    var basedOnSessionForMeta: String? {
        if case .basedOn(let sessionId) = self { return sessionId }
        return nil
    }

    /// `SessionMeta.profileId` to record for this applied seed (`docs/design/41-meeting-profiles.md`
    /// §2.3): non-nil only for a *successfully* resolved `.profile` -- `.profileFallback`
    /// deliberately never records an id (§4: "meta.profile_id は記録しない").
    var profileIdForMeta: String? {
        if case .profile(let id) = self { return id }
        return nil
    }
}

// MARK: - DraftCreationResult

/// `SessionStore.createDraftSession(seed:)`'s result: the new session's `meta.json` snapshot plus
/// what was actually applied (`docs/design/41-meeting-profiles.md` §3.1). The thin compatibility
/// wrapper `createDraftSession(basedOn:)` discards `appliedSeed` and returns `.meta` alone, since
/// every pre-profiles call site only ever needed the meta.
struct DraftCreationResult: Equatable, Sendable {
    var meta: SessionMeta
    var appliedSeed: AppliedDraftSeed
}

// MARK: - PrepCopyScope

/// Which Prep-tab files `SessionHandle.copyPrepFiles(from:scope:)` should overwrite when copying
/// from another session (kikimi.md 10 章 "他セッションから複製").
enum PrepCopyScope: Sendable {
    case contextOnly
    case templateOnly
    case both
}

// MARK: - EnabledWatchersFile

/// Thin YAML transport shape for `watchers/enabled.yaml` / `~/.config/kikimi/default_watchers.yaml`
/// (design doc section 11, kikimi.md 9 章): both files hold a single `enabled: [...]` key. Shared by
/// `SessionStore` (reading the global default list) and `SessionHandle` (reading/writing the
/// session-local list); neither exposes this type itself, only the underlying `[String]`.
struct EnabledWatchersFile: Codable {
    var enabled: [String]
}

// MARK: - FileManager.realHomeDirectory

extension FileManager {
    /// Resolves the invoking user's real home directory via `getpwuid(getuid())`, falling back to
    /// `homeDirectoryForCurrentUser` if that lookup fails. Matches Chirami's
    /// `Chirami/Config/YAMLStore.swift` (`docs/references/chirami-map.md` 7 章): `getpwuid` stays
    /// correct even when the process is run under `sudo`, where `NSHomeDirectory()`/
    /// `homeDirectoryForCurrentUser` can report the invoking `sudo` user's home instead of the
    /// original user's.
    static var realHomeDirectory: URL {
        if let passwd = getpwuid(getuid()) {
            return URL(fileURLWithPath: String(cString: passwd.pointee.pw_dir))
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// Expands a leading `~`/`~/...` in a `config.yaml` path value to `Self.realHomeDirectory`
    /// (`docs/design/05-watcher-runner.md` §3.2's "config パスのチルダ展開ヘルパは新設する... 既存に共通ヘルパは
    /// 無く、ad-hoc な `NSString.expandingTildeInPath` が散在。1つ作りそこに寄せる"). Deliberately not
    /// `NSString.expandingTildeInPath` (used elsewhere, e.g. `LLMProcessRunner`'s CLI candidate
    /// paths): that resolves against `NSHomeDirectory()`, which can diverge from the
    /// `getpwuid`-based `realHomeDirectory` above under `sudo` (see that property's doc comment).
    /// `path` values with no leading `~` are returned unchanged (already absolute, or relative to
    /// the process's current directory -- callers of this helper only ever pass `config.yaml`
    /// path-shaped strings, which are documented as `~`-rooted or absolute).
    static func expandingTildePath(_ path: String) -> URL {
        if path == "~" {
            return realHomeDirectory
        }
        if path.hasPrefix("~/") {
            return realHomeDirectory.appendingPathComponent(String(path.dropFirst(2)))
        }
        return URL(fileURLWithPath: path)
    }
}
