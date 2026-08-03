import Foundation

// MARK: - WindowManager + control socket

/// What `ControlSocketServer` needs to know about open windows (`docs/design/46-control-socket.md`
/// §4). Its own file for `file_length`, the same split `WindowManager+Profiles.swift` made.
extension WindowManager {
    /// Sessions whose workspace window is open and whose state is Paused.
    ///
    /// The control socket refuses an update for these: recording is off, but the meeting is not
    /// over -- the window is on screen and the user can resume any moment (kikimi.md 4 章 "「停止」と
    /// 「終了」を分離する"). A Paused session with no window open is a leftover from an earlier
    /// meeting and deliberately absent here, which is what lets the check drop the initial
    /// version's "paused within the last 30 minutes" time heuristic.
    var openPausedSessionIds: [String] {
        workspaceControllers.values
            .filter { $0.viewModel.meta.state == .paused }
            .map(\.sessionId)
    }
}
