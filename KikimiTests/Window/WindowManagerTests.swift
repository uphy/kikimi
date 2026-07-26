import Foundation
import Testing

@testable import Kikimi

/// Unit tests for `WindowRestorationPlan.sessionIdsToRestore(from:)`
/// (`Kikimi/Window/WindowManager.swift`, `docs/design/06-ui-panels.md` section 9).
///
/// `WindowManager` itself talks to the `SessionStore`/`AppState` singletons and constructs real
/// `NSWindowController` subclasses (`MeetingWorkspaceWindowController`/`SessionListWindowController`/
/// `SettingsWindowController`), so per section 12's own scoping (mirrored by
/// `SessionListViewModelTests.swift`'s treatment of `SessionListViewModel`/`WindowManager`) this
/// suite exercises the pure `WindowRestorationPlan` core directly against fixture `KikimiStateData`
/// values, rather than driving `WindowManager.launch()` end to end — that orchestration is instead
/// covered by the `kikimi-verify` skill (section 12, layer 2: "起動 → Draft ウィンドウを2つ以上同時に
/// 開けること").
@Suite("WindowRestorationPlan")
struct WindowRestorationPlanTests {
    // MARK: - Fixtures

    private func windowState(
        sessionId: String,
        visible: Bool,
        activeTab: MeetingWorkspaceTab = .prep
    ) -> WorkspaceWindowState {
        WorkspaceWindowState(
            sessionId: sessionId,
            x: 100,
            y: 100,
            width: 800,
            height: 600,
            visible: visible,
            activeTab: activeTab
        )
    }

    // MARK: - Empty state

    @Test("an empty windows list restores nothing")
    func emptyWindowsRestoresNothing() {
        let state = KikimiStateData(windows: [])
        #expect(WindowRestorationPlan.sessionIdsToRestore(from: state) == [])
    }

    // MARK: - visible == true is the only thing that matters

    @Test("a single visible entry is restored")
    func singleVisibleEntryIsRestored() {
        let state = KikimiStateData(windows: [windowState(sessionId: "session-a", visible: true)])
        #expect(WindowRestorationPlan.sessionIdsToRestore(from: state) == ["session-a"])
    }

    @Test("a single hidden entry is not restored (section 9: position/size memory only)")
    func singleHiddenEntryIsNotRestored() {
        let state = KikimiStateData(windows: [windowState(sessionId: "session-a", visible: false)])
        #expect(WindowRestorationPlan.sessionIdsToRestore(from: state) == [])
    }

    @Test("only visible == true entries are restored out of a mixed list, preserving their relative order")
    func mixedListRestoresOnlyVisibleEntriesInOrder() {
        let state = KikimiStateData(windows: [
            windowState(sessionId: "hidden-1", visible: false),
            windowState(sessionId: "visible-1", visible: true),
            windowState(sessionId: "hidden-2", visible: false),
            windowState(sessionId: "visible-2", visible: true)
        ])

        #expect(WindowRestorationPlan.sessionIdsToRestore(from: state) == ["visible-1", "visible-2"])
    }

    @Test("every entry hidden restores nothing, even with several windows on record")
    func allHiddenRestoresNothing() {
        let state = KikimiStateData(windows: [
            windowState(sessionId: "a", visible: false),
            windowState(sessionId: "b", visible: false),
            windowState(sessionId: "c", visible: false)
        ])

        #expect(WindowRestorationPlan.sessionIdsToRestore(from: state).isEmpty)
    }

    @Test("every entry visible restores all of them, preserving on-disk order")
    func allVisibleRestoresAllInOrder() {
        let state = KikimiStateData(windows: [
            windowState(sessionId: "third", visible: true),
            windowState(sessionId: "first", visible: true),
            windowState(sessionId: "second", visible: true)
        ])

        // Order follows `state.windows`' array order (kikimi.md 12 章's `windows:` list), not any
        // re-sort by session id/creation time — restoration is a straight left-to-right walk
        // (section 9's sequence diagram: "loop AppState.windows のうち visible == true").
        #expect(WindowRestorationPlan.sessionIdsToRestore(from: state) == ["third", "first", "second"])
    }

    @Test("activeTab and frame fields do not influence whether an entry is restored")
    func activeTabAndFrameDoNotInfluenceRestoration() {
        let state = KikimiStateData(windows: [
            windowState(sessionId: "meeting-tab", visible: true, activeTab: .meeting),
            windowState(sessionId: "watchers-tab", visible: false, activeTab: .watchers)
        ])

        #expect(WindowRestorationPlan.sessionIdsToRestore(from: state) == ["meeting-tab"])
    }
}
