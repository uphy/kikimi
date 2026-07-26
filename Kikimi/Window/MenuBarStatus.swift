import Combine
import Foundation

// MARK: - MenuBarStatus

/// Pure decision logic for `KikimiApp`'s `MenuBarExtra` label/menu content
/// (`docs/design/18-recording-window-stow-and-compact.md` §4.2/§3.3), factored out into a plain,
/// `WindowManager`/AppKit-free `derive` so it is directly unit-testable -- the same pattern
/// `WindowRestorationPlan` (`Kikimi/Window/WindowManager.swift`) and `WindowCloseDecision`
/// (`Kikimi/Window/MeetingWorkspaceWindowController.swift`) already use for their own pure cores.
struct MenuBarStatus: Equatable {
    /// Which SF Symbol the menu bar label shows, in priority order (§3.3's table): a warning on the
    /// Recording session always wins over the plain Recording indicator, which in turn wins over the
    /// idle `waveform` (shown whenever nothing is Recording, including a merely-stowed Paused window).
    enum Icon: Equatable {
        case idle // waveform
        case recording // record.circle.fill
        case warning // exclamationmark.triangle.fill
    }

    /// One "<タイトル> を表示" menu row (§3.3). `title` has already had an empty title replaced with
    /// "無題の会議" -- `MenuBarMenuView` never has to special-case that itself.
    struct HiddenWindowItem: Equatable, Identifiable {
        var id: String // sessionId
        var title: String
    }

    var icon: Icon
    /// Non-`nil` only while `isRecording` (§3.3: "経過時間は Recording 中のみ表示"), formatted via
    /// `TimeFormatting.clock(seconds:)` (`Kikimi/Views/MeetingWorkspace/MeetingWorkspaceView.swift`).
    var timerText: String?
    /// Non-`nil` only while `isRecording`, backing the menu's disabled "録音中: <タイトル>" info row
    /// (§3.3). This value alone also feeds `MenuBarMenuContent.derive`, so it carries no elapsed
    /// time itself -- see that type's doc comment for why the menu body must never show one.
    var recordingTitle: String?
    /// Every currently-stowed session's menu row, Recording-session-first (§3.3: "Recording 中でしまって
    /// あるものが先頭").
    var hiddenWindows: [HiddenWindowItem]

    static let idle = MenuBarStatus(icon: .idle, timerText: nil, recordingTitle: nil, hiddenWindows: [])

    /// - Parameters:
    ///   - isRecording: Derived from the Recording session's `recordingButtonState` (`case
    ///     .recording` only), **not** from `WindowManager.recordingSessionId` being non-nil --
    ///     `.ending`'s transitional state must read as "not Recording" here (§3.3: "`.ending` の数秒間
    ///     に録音アイコンが出続けるのを防ぐ").
    ///   - elapsedSeconds: The Recording session's elapsed seconds, if `isRecording`.
    ///   - recordingTitle: The Recording session's title (already blank-substituted), if `isRecording`.
    ///   - recordingHasWarning: Whether the Recording session's `banners` is non-empty (§3.3: "警告判定
    ///     は録音中セッションのみを対象にする" -- a stowed *Paused* session's banners must never
    ///     contribute here).
    ///   - hiddenWindows: Every stowed session's menu item, already ordered/blank-substituted by the
    ///     caller.
    static func derive(
        isRecording: Bool,
        elapsedSeconds: Int?,
        recordingTitle: String?,
        recordingHasWarning: Bool,
        hiddenWindows: [HiddenWindowItem]
    ) -> MenuBarStatus {
        let icon: Icon
        if isRecording && recordingHasWarning {
            icon = .warning
        } else if isRecording {
            icon = .recording
        } else {
            icon = .idle
        }

        return MenuBarStatus(
            icon: icon,
            timerText: isRecording ? elapsedSeconds.map { TimeFormatting.clock(seconds: $0) } : nil,
            recordingTitle: isRecording ? recordingTitle : nil,
            hiddenWindows: hiddenWindows
        )
    }
}

// MARK: - MenuBarStatusModel

/// `WindowManager`-owned, `@MainActor` `ObservableObject` wrapper around the latest `MenuBarStatus`
/// (`docs/design/18-recording-window-stow-and-compact.md` §4.2). `KikimiApp`'s `MenuBarLabelView`
/// (and only that view -- **not** `MenuBarMenuView`, see `MenuBarMenuModel` below) observes this
/// directly; all of the actual derive logic lives in `MenuBarStatus.derive` above -- this type
/// exists purely so `WindowManager` (an `ObservableObject` in its own right, but whose `@Published`
/// properties are all recording-lifecycle-specific) has a separate, single-purpose publication
/// point for the menu bar label's UI.
@MainActor
final class MenuBarStatusModel: ObservableObject {
    @Published private(set) var status: MenuBarStatus = .idle

    /// `internal` (not `private`): `WindowManager` is the sole writer, from a separate file/type.
    func update(_ status: MenuBarStatus) {
        self.status = status
    }
}

// MARK: - MenuBarMenuContent

/// The `MenuBarExtra` **menu body**'s own projection of `MenuBarStatus` -- deliberately excludes
/// `timerText` (`docs/design/18-recording-window-stow-and-compact.md` §3.3/§4.2/§6 failure mode
/// #15). `MenuBarStatusModel.status` changes every second while Recording (the elapsed-time
/// label), and `MenuBarExtra(.menu)`'s content view re-evaluating while the menu is open rebuilds
/// its backing `NSMenu` items, resetting whatever row the user's mouse is currently hovering back
/// to the first row. `MenuBarMenuView` must therefore never observe `MenuBarStatus` (or anything
/// containing `timerText`) directly -- only this `timerText`-free `Equatable` value, published
/// through the separate `MenuBarMenuModel` below only when it actually changes.
struct MenuBarMenuContent: Equatable {
    /// Non-`nil` only while Recording -- backs both the disabled "録音中: <title>" info row and the
    /// "会議を終了…" item's visibility (§3.3). No elapsed time here by design: the live count is the
    /// menu bar label's job (`MenuBarStatus.timerText`/`MenuBarLabelView`), not the menu body's.
    var recordingTitle: String?
    /// Every currently-stowed session's "<タイトル> を表示" row, Recording-session-first --
    /// unchanged pass-through of `MenuBarStatus.hiddenWindows`.
    var hiddenWindows: [MenuBarStatus.HiddenWindowItem]

    static func derive(from status: MenuBarStatus) -> MenuBarMenuContent {
        MenuBarMenuContent(recordingTitle: status.recordingTitle, hiddenWindows: status.hiddenWindows)
    }
}

// MARK: - MenuBarMenuModel

/// `WindowManager`-owned, `@MainActor` `ObservableObject` that `KikimiApp`'s `MenuBarMenuView` (and
/// only that view -- never `MenuBarLabelView`) observes (`docs/design/
/// 18-recording-window-stow-and-compact.md` §4.2/§3.3). Deliberately a **separate instance** from
/// `MenuBarStatusModel`, not a second `@Published` property on the same type: `ObservableObject`'s
/// `objectWillChange` fires for *any* `@Published` change on the object, regardless of which
/// property changed, so sharing one object between the once-a-second timer tick
/// (`MenuBarStatusModel.status.timerText`) and the menu body would still rebuild the menu every
/// second even if the menu body only ever read `content`.
@MainActor
final class MenuBarMenuModel: ObservableObject {
    @Published private(set) var content: MenuBarMenuContent = MenuBarMenuContent(recordingTitle: nil, hiddenWindows: [])

    /// Publishes only when `newValue` actually differs from the current `content` (§4.2: "値が実際に
    /// 変わったときだけ publish する"). This is what makes the once-a-second `recomputeMenuBarStatus()`
    /// call in `WindowManager` harmless for the open menu: `timerText`-only changes derive to an
    /// unchanged `MenuBarMenuContent` and this guard drops them before `@Published` ever fires
    /// `objectWillChange`.
    func update(_ newValue: MenuBarMenuContent) {
        guard newValue != content else { return }
        content = newValue
    }
}
