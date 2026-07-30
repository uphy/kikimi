import Foundation

// MARK: - WatcherRunRecord

/// `watchers/<id>.run.json`: what the run that produced the current `watchers/<id>.state.json`
/// actually did (`docs/design/05-watcher-runner.md` §7.2). Written by `WatcherRunner` immediately
/// after the state it describes, and read back by `MeetingWorkspaceViewModel.renderExistingState(for:)`
/// when a session is reopened.
///
/// Exists because `state.json` holds the Watcher's schema-validated LLM output *verbatim* and
/// nothing else, so a reopened session had no way to answer two questions about the result it was
/// rendering: when it was produced (the footer said "未実行" under a real result) and what input it
/// was produced from (the `input_scope` badge could only describe the definition's *current* value,
/// which may have been edited since).
///
/// Absent for any Watcher whose last run predates this file, so every reader treats it as optional
/// and degrades rather than failing -- see `renderExistingState(for:)`'s mtime fallback.
struct WatcherRunRecord: Codable, Sendable, Equatable {
    /// When the run finished, from `WatcherRunner`'s injected clock -- the same value its
    /// `WatcherEvent.Kind.finished(at:)` carries.
    var finishedAt: Date
    /// The `input_scope` in effect for that run, encoded as its `scalarValue` string.
    var inputScope: WatcherInputScope
}
