import Foundation

// MARK: - SessionFileError

/// Failure modes for `SessionFile`/`GenericAccessibleFile` path resolution. See
/// `docs/design/07-session-store.md` section 5.2.
enum SessionFileError: LocalizedError, Equatable, Sendable {
    /// A `.watcherDefinition(id:)`/`.watcherState(id:)` case (or the equivalent
    /// `GenericAccessibleFile` case) was resolved with a watcher id containing characters other
    /// than ASCII letters, digits, or hyphens (kikimi.md 9 章 "Watcher ファイル形式": "id はファイル名の
    /// 英数字・ハイフンのみ許容"). Rejecting this here also blocks path traversal via ids like
    /// `"../../etc"` from ever reaching `FileManager`.
    case invalidWatcherId(String)

    var errorDescription: String? {
        switch self {
        case .invalidWatcherId(let id):
            return "Invalid watcher id \"\(id)\": only ASCII letters, digits, and hyphens are allowed."
        }
    }
}

// MARK: - SessionFile

/// Every known file kind inside a session directory (`~/.local/state/kikimi/sessions/<id>/`),
/// and the single place that resolves each kind to its path relative to that directory.
///
/// This is the "one true way" to name a file inside a session: `SessionHandle` is meant to be the
/// only place in the app that constructs `SessionFile` values and calls `relativePath()` on them,
/// so no other component ever builds a session-relative path (or a watcher id-derived path, which
/// needs the validation below) by hand. Swift's access control can't literally restrict a type to
/// "usable only from `SessionHandle.swift`" when that's a different file in the same module —
/// `fileprivate` would also hide it from `SessionHandle.swift` itself, and `private`/`fileprivate`
/// members are invisible even via `@testable import`, which this module's test target relies on
/// (`KikimiTests/SessionStore/SessionFileTests.swift`). So this type stays at the default
/// (`internal`) access level, and the "don't use this outside `SessionHandle.swift`" rule from
/// `docs/design/07-session-store.md` section 5.2 is enforced by convention/review rather than by
/// the compiler. External callers (`RefinementQueue`/`SummaryUpdater`/`WatcherRunner`/UI) that only
/// need the generic `readJSON`/`writeJSON`/`readText`/`writeText` primitives should go through
/// `GenericAccessibleFile` instead, which intentionally cannot express `.meta`/`.context`/
/// `.summaryTemplate`/`.transcriptJSONL`/`.refinedJSONL`/`.diarizationJSONL`/`.speakerAssignments`/
/// `.participants`/`.watchersEnabled` (section 5.2.1).
enum SessionFile: Sendable, Equatable {
    case meta
    case context
    case summaryTemplate
    case transcriptJSONL
    case refinedJSONL
    /// `diarization.jsonl`: append-only log of finalized speaker turns emitted by the realtime
    /// diarizer (`docs/design/13-speaker-diarization.md` section 4.2). Same "追記のみ・rewrite 禁止"
    /// contract as `.transcriptJSONL`/`.refinedJSONL`.
    case diarizationJSONL
    /// `speaker_assignments.json`: slot -> display-name mapping (design section 4.3). Whole-file
    /// overwrite, but only ever through `SessionHandle.updateSpeakerAssignments(_:)`'s
    /// mutate-closure API — see that method's doc comment for why a plain read-modify-write isn't
    /// safe here.
    case speakerAssignments
    /// `participants.json`: the optional per-session participant roster
    /// (`docs/design/22-participant-hints.md` section 1.1/1.2). Whole-file overwrite, but only ever
    /// through `SessionHandle.updateParticipants(_:)`'s mutate-closure API -- same "auto-add from a user
    /// action racing a concurrent UI edit" rationale as `.speakerAssignments`/
    /// `updateSpeakerAssignments(_:)` above.
    case participants
    case summaryState
    case summaryMarkdown
    /// `llm_usage.jsonl`: append-only log of per-call LLM token usage/cost records
    /// (`docs/design/16-llm-usage-stats.md` section 2). Same "追記のみ・rewrite 禁止" contract as
    /// `.transcriptJSONL`/`.refinedJSONL`, with its own dedicated
    /// `appendLLMUsageRecord`/`readLLMUsageRecords` API (`SessionHandle+LLMUsage.swift`).
    case llmUsageJSONL
    case watchersEnabled
    /// `watchers/<id>.md`. `id` must be non-empty and contain only ASCII letters, digits, and
    /// hyphens (kikimi.md 9 章); `relativePath()` validates this and throws
    /// `SessionFileError.invalidWatcherId` otherwise.
    case watcherDefinition(id: String)
    /// `watchers/<id>.state.json`. Same `id` constraints as `.watcherDefinition(id:)`.
    case watcherState(id: String)

    /// Resolves this case to a path relative to the session directory root, e.g.
    /// `.watcherState(id: "pre-check")` -> `"watchers/pre-check.state.json"`. A pure function:
    /// same input always produces the same output (or the same thrown error), with no I/O.
    ///
    /// Throws `SessionFileError.invalidWatcherId` for `.watcherDefinition`/`.watcherState` cases
    /// whose `id` fails the kikimi.md 9 章 validation (non-empty, `[A-Za-z0-9-]` only).
    func relativePath() throws -> String {
        switch self {
        case .meta:
            return "meta.json"
        case .context:
            return "context.md"
        case .summaryTemplate:
            return "summary_template.md"
        case .transcriptJSONL:
            return "transcript.jsonl"
        case .refinedJSONL:
            return "refined.jsonl"
        case .diarizationJSONL:
            return "diarization.jsonl"
        case .speakerAssignments:
            return "speaker_assignments.json"
        case .participants:
            return "participants.json"
        case .summaryState:
            return "summary.state.json"
        case .summaryMarkdown:
            return "summary.md"
        case .llmUsageJSONL:
            return "llm_usage.jsonl"
        case .watchersEnabled:
            return "watchers/enabled.yaml"
        case .watcherDefinition(let id):
            try Self.validateWatcherId(id)
            return "watchers/\(id).md"
        case .watcherState(let id):
            try Self.validateWatcherId(id)
            return "watchers/\(id).state.json"
        }
    }

    /// ASCII letters, digits, and `-` only (kikimi.md 9 章). Deliberately does not use
    /// `Character.isLetter`/`.isNumber`, which are Unicode-aware and would accept characters
    /// (e.g. kanji, full-width digits) outside the intended filename-safe ASCII set.
    private static let allowedWatcherIdCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-"
    )

    private static func validateWatcherId(_ id: String) throws {
        guard !id.isEmpty, id.unicodeScalars.allSatisfy({ allowedWatcherIdCharacters.contains($0) }) else {
            throw SessionFileError.invalidWatcherId(id)
        }
    }
}

// MARK: - GenericAccessibleFile

/// The subset of `SessionFile` cases that `SessionHandle`'s generic
/// `readJSON`/`writeJSON`/`readText`/`writeText` primitives (`docs/design/07-session-store.md`
/// section 11) are allowed to touch.
///
/// `SessionFile` itself deliberately is not used as the parameter type for those primitives:
/// doing so would let a caller pass `.transcriptJSONL` (an append-only log with its own
/// `appendTranscriptSegment`/`readTranscriptSegments` API) or `.context` (which has its own
/// `writeContext(_:)` with a 32KB-limit warning) straight into a generic overwrite, silently
/// bypassing those dedicated APIs and their invariants. `GenericAccessibleFile` only lists the
/// cases that have no dedicated API of their own, so `.meta`/`.context`/`.summaryTemplate`/
/// `.transcriptJSONL`/`.refinedJSONL`/`.watchersEnabled` are not expressible here — passing one of
/// those to a generic primitive is a compile error rather than a runtime misuse. `.diarizationJSONL`
/// (append-only, own `appendDiarizationTurn`/`readDiarizationTurns` API) and `.speakerAssignments`
/// (own mutate-closure `updateSpeakerAssignments(_:)` API, for the same "auto vs. user write can
/// race" reason `.meta`/`updateMeta(_:)` is excluded) are likewise not expressible here
/// (`docs/design/13-speaker-diarization.md` section 4.1). `.participants` (own mutate-closure
/// `updateParticipants(_:)` API, same race rationale) is excluded for the identical reason
/// (`docs/design/22-participant-hints.md` section 1.2).
enum GenericAccessibleFile: Sendable, Equatable {
    case summaryState
    case summaryMarkdown
    /// Same `id` constraints as `SessionFile.watcherDefinition(id:)`.
    case watcherDefinition(id: String)
    /// Same `id` constraints as `SessionFile.watcherState(id:)`.
    case watcherState(id: String)

    /// Bridges to the corresponding `SessionFile` case for path resolution. Intended for
    /// `SessionHandle`'s internal use only (see `SessionFile`'s doc comment for why this can't be
    /// a literal `fileprivate` member across `SessionFile.swift`/`SessionHandle.swift`).
    var asSessionFile: SessionFile {
        switch self {
        case .summaryState:
            return .summaryState
        case .summaryMarkdown:
            return .summaryMarkdown
        case .watcherDefinition(let id):
            return .watcherDefinition(id: id)
        case .watcherState(let id):
            return .watcherState(id: id)
        }
    }

    /// Convenience equivalent to `asSessionFile.relativePath()`, so callers that only need the
    /// resolved path don't need to go through the bridge themselves. Same validation/throwing
    /// behavior as `SessionFile.relativePath()`.
    func relativePath() throws -> String {
        try asSessionFile.relativePath()
    }
}
