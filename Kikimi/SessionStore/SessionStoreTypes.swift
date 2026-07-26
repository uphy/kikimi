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
