import Foundation

// MARK: - WindowManager + Profiles (`docs/design/41-meeting-profiles.md` §3.3/§6.2)

/// Split out of `WindowManager.swift` purely to stay under `file_length` -- `profileMenuItems`
/// itself (the stored property `refreshProfileMenu()` writes) and `recomputeMenuBarStatus()` (the
/// republish step it triggers) still live on `WindowManager` proper, deliberately made non-`private`
/// for this file to reach (see their doc comments in `WindowManager.swift`), the same convention
/// `SessionStore+Defaults.swift` uses against `SessionStore.swift`.
@MainActor
extension WindowManager {
    /// Re-reads `profiles.dir` via `MeetingProfileStore.shared.list()` and republishes
    /// `menuBarMenu` so the "新規セッション" submenu's プロファイル一覧 reflects it (§6.2). Call at
    /// exactly the three defined refresh points -- launch (`WindowManager.launch()`), after the
    /// プロファイルとして保存… sheet completes, and after a rename/delete in the Settings プロファイル
    /// タブ -- **never** on every menu open: `MenuBarMenuContent` is derived synchronously from
    /// `@MainActor` state for a `MenuBarExtra(.menu)` body, and `MeetingProfileStore` is an actor
    /// whose `list()` is `async`, so reading it live from that body is not an option (§6.2's "メニュー
    /// 構築時にディスクを読む形にはしない").
    ///
    /// Fire-and-forget by design, matching `AppDelegate`'s own non-blocking `Task { await
    /// WindowManager.shared.launch() }` at startup: nothing here can fail in a way a caller could
    /// usefully react to (`MeetingProfileStore.list()` itself already swallows unreadable profile
    /// directories into a `.warning` log, per its own contract), so there is nothing to `throw`.
    func refreshProfileMenu() {
        Task { [weak self] in
            guard let self else { return }
            let profiles = await MeetingProfileStore.shared.list()
            self.profileMenuItems = profiles.map { MenuBarMenuContent.ProfileItem(id: $0.id, name: $0.name) }
            self.recomputeMenuBarStatus()
        }
    }
}
