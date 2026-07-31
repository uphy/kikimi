import Foundation

// MARK: - WatcherPanelItem

/// One Watchers-tab sub-tab / Prep-tab management row's worth of live state
/// (`docs/design/05-watcher-runner.md` §2.5). Built and kept live entirely by
/// `MeetingWorkspaceViewModel+Watchers.swift` -- the core `Kikimi/Watchers/` engine (`WatcherRunner`/
/// `WatcherLibrary`) has no notion of this type; it only vends the lower-level `WatcherEvent`/
/// `WatcherOrigin` this file consumes to build it.
///
/// Split out of `MeetingWorkspaceViewModel+Watchers.swift` (with `SimpleWatcherSpecDraft` and the
/// two error enums below) to keep that file under the project's `file_length` lint limit.
struct WatcherPanelItem: Sendable, Identifiable, Equatable {
    var id: String
    var name: String
    var origin: WatcherOrigin
    /// Whether this row's definition desugars from a `kind: simple` file
    /// (`docs/design/34-simple-watchers.md` §6.3), set by `refreshWatcherItems()` from
    /// `definition.simpleSpec != nil`. Drives the Prep tab's edit routing (simple form vs. text
    /// editor); always `false` for `origin: .missing` since there's no definition to inspect.
    var isSimple: Bool
    /// The definition's *current* `input_scope`, surfaced in the Watchers-tab footer so a reader can
    /// tell at a glance how much of the meeting the displayed result was allowed to see (the picker
    /// itself is buried behind 管理 → 編集, so without this the only way to find out was opening the
    /// `.md`). `nil` for `origin: .missing`, where there is no definition to read it from.
    ///
    /// Describes the *next* run. What the result currently on screen was produced from is
    /// `lastRunInputScope` -- the footer shows both when they disagree.
    var inputScope: WatcherInputScope?
    /// The `input_scope` the run that produced `renderedMarkdown` actually used, recovered from
    /// `watchers/<id>.run.json` (`WatcherRunRecord`). `nil` when that file predates this feature or
    /// the Watcher has never run, in which case the footer falls back to `inputScope` alone.
    var lastRunInputScope: WatcherInputScope?
    /// The latest view-template rendering, `nil` until either the initial LLM-free render
    /// (`refreshWatcherItems()`) or a first `WatcherEvent.Kind.finished` populates it.
    var renderedMarkdown: String?
    var status: Status
    /// When the run behind `renderedMarkdown` finished. Comes either from a live
    /// `WatcherEvent.Kind.finished(at:)` this process observed, or -- for a session opened fresh --
    /// from `watchers/<id>.run.json`, falling back to `watchers/<id>.state.json`'s mtime for results
    /// written before that file existed (`renderExistingState(for:)`).
    var lastRunAt: Date?

    enum Status: Sendable, Equatable {
        case idle
        case running
        case error(String)

        var isError: Bool {
            if case .error = self { return true }
            return false
        }
    }
}

// MARK: - SimpleWatcherSpecDraft

/// The simple form's id-less input surface (`docs/design/34-simple-watchers.md` §6.3):
/// `SimpleWatcherSpec` minus `id`, which `createSimpleWatcher(_:)` generates on the caller's behalf.
/// `model` isn't exposed as a form field (§6.2) but is carried through so an existing hand-authored
/// `model:` isn't silently dropped by an edit -- see `updateSimpleWatcher(id:_:)`'s doc comment.
struct SimpleWatcherSpecDraft: Sendable, Equatable {
    var name: String
    var model: String?
    var prompt: String
    var trigger: WatcherTrigger
    var inputScope: WatcherInputScope

    /// Attaches `id` to complete a `SimpleWatcherSpec` -- shared by `createSimpleWatcher(_:)` (a
    /// freshly generated id) and `updateSimpleWatcher(id:_:)` (an existing one).
    func spec(id: String) -> SimpleWatcherSpec {
        SimpleWatcherSpec(id: id, name: name, model: model, trigger: trigger, inputScope: inputScope, prompt: prompt)
    }
}

// MARK: - LocalWatcherCreationError

/// Failure modes for `MeetingWorkspaceViewModel.createLocalWatcher(id:)`.
enum LocalWatcherCreationError: LocalizedError, Equatable, Sendable {
    case invalidId(String)
    case alreadyExists(String)

    var errorDescription: String? {
        switch self {
        case .invalidId(let id):
            return "無効なWatcher IDです: \"\(id)\"（英数字とハイフンのみ使用できます）"
        case .alreadyExists(let id):
            return "Watcher \"\(id)\" は既に存在します。"
        }
    }
}

// MARK: - SimpleWatcherConversionError

/// Failure modes for `MeetingWorkspaceViewModel.convertSimpleWatcherToFull(id:)`
/// (`docs/design/34-simple-watchers.md` §7). Both cases mean the on-disk `.md` was left untouched.
enum SimpleWatcherConversionError: LocalizedError, Equatable, Sendable {
    /// The generated full-format text failed to parse. `detail` is the underlying parse error's own
    /// `errorDescription` (or a `String(describing:)` fallback), not a hardcoded cause -- §7 asks for
    /// a "汎用形" message that surfaces whatever actually went wrong.
    case parseFailed(detail: String)
    /// The generated text parsed cleanly but its `WatcherDefinition` (minus `simpleSpec`) doesn't
    /// match `spec.desugar(promptTemplate:)`. The only known cause is a `# `-prefixed line in the
    /// prompt colliding with the `# System`/`# User` section split (§8.2).
    case roundTripMismatch

    var errorDescription: String? {
        switch self {
        case .parseFailed(let detail):
            return "詳細形式への変換に失敗しました: \(detail)"
        case .roundTripMismatch:
            return "プロンプトに \"# \" で始まる行が含まれているため変換できません。行頭の \"#\" を減らすか削除してください。"
        }
    }
}
