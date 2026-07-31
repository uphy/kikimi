import Foundation
import Testing

@testable import Kikimi

/// Unit tests for `MenuBarStatus.derive` (`Kikimi/Window/MenuBarStatus.swift`,
/// `docs/design/18-recording-window-stow-and-compact.md` §4.2/§3.3/§7).
///
/// `WindowManager` is the sole caller that gathers `derive`'s inputs (`recomputeMenuBarStatus()`),
/// but it is a hard-wired singleton bound to the real `SessionStore`/`AppState` (see
/// `WindowManagerTests.swift`'s own doc comment) -- this suite exercises the pure `derive` core
/// directly, the same scoping choice that file already makes for `WindowRestorationPlan`.
///
/// Two things `derive` itself does **not** do (left to its private `WindowManager` callers, and so
/// out of reach for direct unit testing without the singleton -- see this file's final `@Suite` for
/// the explicit note): computing `hiddenWindows`' Recording-session-first ordering
/// (`WindowManager.hiddenWindowItems()`) and blank-title substitution
/// (`WindowManager.displayTitle(_:)`, `private`). `derive` only ever receives already-ordered,
/// already-substituted `HiddenWindowItem`s and must thread them through unchanged -- several tests
/// below assert exactly that pass-through contract.
@Suite("MenuBarStatus.derive")
struct MenuBarStatusDeriveTests {
    private func hiddenItem(_ id: String, _ title: String) -> MenuBarStatus.HiddenWindowItem {
        MenuBarStatus.HiddenWindowItem(id: id, title: title)
    }

    // MARK: - Icon priority: idle / recording / warning

    @Test("not Recording always yields .idle, regardless of recordingHasWarning or hiddenWindows")
    func notRecordingYieldsIdle() {
        for recordingHasWarning in [false, true] {
            let status = MenuBarStatus.derive(
                isRecording: false,
                elapsedSeconds: 999, // must be ignored entirely while not Recording
                recordingTitle: "should be ignored",
                recordingHasWarning: recordingHasWarning,
                hiddenWindows: [hiddenItem("a", "Session A")]
            )
            #expect(status.icon == .idle)
            #expect(status.timerText == nil)
            #expect(status.recordingTitle == nil)
        }
    }

    @Test("Recording without a warning yields .recording, with timerText/recordingTitle populated")
    func recordingWithoutWarningYieldsRecordingIcon() {
        let status = MenuBarStatus.derive(
            isRecording: true,
            elapsedSeconds: 75,
            recordingTitle: "デイリースクラム",
            recordingHasWarning: false,
            hiddenWindows: []
        )
        #expect(status.icon == .recording)
        #expect(status.timerText == TimeFormatting.clock(seconds: 75))
        #expect(status.recordingTitle == "デイリースクラム")
    }

    @Test("Recording with a warning yields .warning (not .recording), while still populating timerText/recordingTitle")
    func recordingWithWarningYieldsWarningIcon() {
        let status = MenuBarStatus.derive(
            isRecording: true,
            elapsedSeconds: 75,
            recordingTitle: "デイリースクラム",
            recordingHasWarning: true,
            hiddenWindows: []
        )
        // §3.3's priority table: warning beats the plain Recording indicator.
        #expect(status.icon == .warning)
        // The elapsed-time/title info row is unaffected by the warning -- only the icon changes.
        #expect(status.timerText == TimeFormatting.clock(seconds: 75))
        #expect(status.recordingTitle == "デイリースクラム")
    }

    @Test("recordingHasWarning is only consulted while isRecording is true (idle wins otherwise)")
    func warningIsIgnoredWhenNotRecording() {
        // A defensive combination that should never occur in practice (a warning is only ever
        // computed for the Recording session), but `derive`'s branch order must not accidentally
        // promote a warning to the icon when isRecording is false.
        let status = MenuBarStatus.derive(
            isRecording: false,
            elapsedSeconds: nil,
            recordingTitle: nil,
            recordingHasWarning: true,
            hiddenWindows: []
        )
        #expect(status.icon == .idle)
    }

    // MARK: - timerText presence/absence

    @Test("timerText is nil while Recording if elapsedSeconds itself is nil")
    func timerTextIsNilWhenElapsedSecondsIsNil() {
        let status = MenuBarStatus.derive(
            isRecording: true,
            elapsedSeconds: nil,
            recordingTitle: "タイトル",
            recordingHasWarning: false,
            hiddenWindows: []
        )
        #expect(status.timerText == nil)
        // recordingTitle is independent of elapsedSeconds -- still populated.
        #expect(status.recordingTitle == "タイトル")
    }

    @Test("recordingTitle is nil while Recording if the caller itself passes nil")
    func recordingTitleIsNilWhenCallerPassesNil() {
        let status = MenuBarStatus.derive(
            isRecording: true,
            elapsedSeconds: 10,
            recordingTitle: nil,
            recordingHasWarning: false,
            hiddenWindows: []
        )
        #expect(status.recordingTitle == nil)
        #expect(status.timerText == TimeFormatting.clock(seconds: 10))
    }

    @Test("timerText formats via TimeFormatting.clock, including the H:MM:SS form past one hour")
    func timerTextUsesClockFormatting() {
        let status = MenuBarStatus.derive(
            isRecording: true,
            elapsedSeconds: 3_725, // 1:02:05
            recordingTitle: nil,
            recordingHasWarning: false,
            hiddenWindows: []
        )
        #expect(status.timerText == "1:02:05")
    }

    // MARK: - hiddenWindows pass-through (ordering/blank-substitution is the caller's job)

    @Test("hiddenWindows is threaded through unchanged, preserving the caller's order")
    func hiddenWindowsPassesThroughUnchangedAndOrdered() {
        let items = [
            hiddenItem("session-recording", "録音中の会議"),
            hiddenItem("session-paused-1", "Paused会議1"),
            hiddenItem("session-paused-2", "Paused会議2")
        ]
        let status = MenuBarStatus.derive(
            isRecording: true,
            elapsedSeconds: 5,
            recordingTitle: "録音中の会議",
            recordingHasWarning: false,
            hiddenWindows: items
        )
        #expect(status.hiddenWindows == items)
    }

    @Test("an already blank-title-substituted hiddenWindows entry is preserved verbatim")
    func hiddenWindowsPreservesAlreadySubstitutedBlankTitle() {
        // Blank-title substitution ("" -> "無題の会議") happens in the caller
        // (`WindowManager.displayTitle(_:)`, private) *before* `derive` ever sees the array --
        // `HiddenWindowItem`'s own doc comment states this explicitly. `derive` must not mangle
        // (or re-substitute) whatever string it's handed.
        let items = [hiddenItem("session-untitled", "無題の会議")]
        let status = MenuBarStatus.derive(
            isRecording: false,
            elapsedSeconds: nil,
            recordingTitle: nil,
            recordingHasWarning: false,
            hiddenWindows: items
        )
        #expect(status.hiddenWindows == items)
        #expect(status.hiddenWindows.first?.title == "無題の会議")
    }

    @Test("hiddenWindows is empty when there is nothing stowed")
    func hiddenWindowsEmptyWhenNothingStowed() {
        let status = MenuBarStatus.derive(
            isRecording: false,
            elapsedSeconds: nil,
            recordingTitle: nil,
            recordingHasWarning: false,
            hiddenWindows: []
        )
        #expect(status.hiddenWindows.isEmpty)
    }

    // MARK: - .idle static default

    @Test(".idle static value matches an all-empty derive() result")
    func idleStaticValueMatchesDefaultDerive() {
        let derived = MenuBarStatus.derive(
            isRecording: false,
            elapsedSeconds: nil,
            recordingTitle: nil,
            recordingHasWarning: false,
            hiddenWindows: []
        )
        #expect(derived == MenuBarStatus.idle)
    }
}

// MARK: - MenuBarStatusModel

/// Unit tests for `MenuBarStatusModel`'s own publication contract (`Kikimi/Window/MenuBarStatus.swift`).
///
/// **Not covered here** (§7's "`recordingSessionId` 変化時に旧 ViewModel の購読解除" requirement):
/// the actual subscribe/rebuild lifecycle lives entirely in `WindowManager
/// .rebuildRecordingStatusSubscriptions()` -- a `private` method driven by `WindowManager`'s own
/// `@Published private(set) var recordingSessionId`, which only ever changes via the real
/// `SessionStore.shared.subscribeToRecordingSessionId()` stream. There is no seam to inject a fake
/// `recordingSessionId` transition or to observe `recordingStatusCancellables` from a test, and
/// exercising this via the live singleton would (per `WindowManagerTests.swift`'s own established
/// scoping) require driving real recording state and risks touching the developer's actual
/// `~/.local/state/kikimi/state.yaml`. This is left to the `kikimi-verify` skill (layer 2) rather
/// than hacked around here.
@Suite("MenuBarStatusModel")
@MainActor
struct MenuBarStatusModelTests {
    @Test("starts at .idle and update(_:) republishes the given status verbatim")
    func updatePublishesGivenStatus() {
        let model = MenuBarStatusModel()
        #expect(model.status == .idle)

        let newStatus = MenuBarStatus(
            icon: .recording,
            timerText: "01:23",
            recordingTitle: "テスト会議",
            hiddenWindows: [MenuBarStatus.HiddenWindowItem(id: "s", title: "しまってある会議")]
        )
        model.update(newStatus)

        #expect(model.status == newStatus)
    }

    @Test("a second update(_:) fully replaces the previous status, not merges it")
    func updateReplacesPreviousStatusEntirely() {
        let model = MenuBarStatusModel()
        model.update(MenuBarStatus(icon: .recording, timerText: "00:05", recordingTitle: "A", hiddenWindows: []))
        model.update(.idle)

        #expect(model.status == .idle)
    }
}

// MARK: - MenuBarMenuContent.derive

/// Unit tests for `MenuBarMenuContent.derive` (`Kikimi/Window/MenuBarStatus.swift`,
/// `docs/design/18-recording-window-stow-and-compact.md` §4.2/§7).
@Suite("MenuBarMenuContent.derive")
struct MenuBarMenuContentDeriveTests {
    private func hiddenItem(_ id: String, _ title: String) -> MenuBarStatus.HiddenWindowItem {
        MenuBarStatus.HiddenWindowItem(id: id, title: title)
    }

    @Test("drops timerText entirely, threading recordingTitle/hiddenWindows through unchanged")
    func dropsTimerTextButKeepsRecordingTitleAndHiddenWindows() {
        let status = MenuBarStatus(
            icon: .recording,
            timerText: "25:12",
            recordingTitle: "デイリースクラム",
            hiddenWindows: [hiddenItem("s1", "Paused会議")]
        )
        let content = MenuBarMenuContent.derive(from: status, profiles: [])

        #expect(content.recordingTitle == "デイリースクラム")
        #expect(content.hiddenWindows == [hiddenItem("s1", "Paused会議")])
    }

    @Test("two statuses differing only in timerText derive to an equal MenuBarMenuContent")
    func timerTextOnlyDifferenceDerivesEqualContent() {
        let base = MenuBarStatus(
            icon: .recording,
            timerText: "00:01",
            recordingTitle: "会議",
            hiddenWindows: [hiddenItem("s1", "会議2")]
        )
        var tickedLater = base
        tickedLater.timerText = "00:02"

        #expect(MenuBarMenuContent.derive(from: base, profiles: []) == MenuBarMenuContent.derive(from: tickedLater, profiles: []))
    }

    @Test("idle status derives to nil recordingTitle and empty hiddenWindows")
    func idleStatusDerivesToEmptyContent() {
        let content = MenuBarMenuContent.derive(from: .idle, profiles: [])

        #expect(content.recordingTitle == nil)
        #expect(content.hiddenWindows.isEmpty)
    }

    // MARK: - profiles pass-through (docs/design/41-meeting-profiles.md §6.2)

    @Test("derive(from:profiles:) threads the given profiles list through unchanged")
    func derivePassesThroughProfilesUnchanged() {
        let items = [
            MenuBarMenuContent.ProfileItem(id: "daily-scrum", name: "デイリースクラム"),
            MenuBarMenuContent.ProfileItem(id: "one-on-one", name: "1on1")
        ]
        let content = MenuBarMenuContent.derive(from: .idle, profiles: items)

        #expect(content.profiles == items)
    }

    @Test("derive(from:profiles:) with an empty profiles list yields an empty profiles array")
    func deriveWithEmptyProfilesYieldsEmptyArray() {
        let content = MenuBarMenuContent.derive(from: .idle, profiles: [])

        #expect(content.profiles.isEmpty)
    }

    @Test("two statuses differing only in timerText, given the same profiles list, still derive to an equal MenuBarMenuContent")
    func timerTextOnlyDifferenceWithProfilesStillDerivesEqualContent() {
        let items = [MenuBarMenuContent.ProfileItem(id: "daily-scrum", name: "デイリースクラム")]
        let base = MenuBarStatus(icon: .recording, timerText: "00:01", recordingTitle: "会議", hiddenWindows: [])
        var tickedLater = base
        tickedLater.timerText = "00:02"

        #expect(MenuBarMenuContent.derive(from: base, profiles: items) == MenuBarMenuContent.derive(from: tickedLater, profiles: items))
    }
}

// MARK: - MenuBarMenuModel

/// Unit tests for `MenuBarMenuModel`'s de-dup publication contract (`Kikimi/Window/MenuBarStatus.swift`,
/// §6 failure mode #15/§7's regression requirement: a Recording session's once-a-second elapsed-time
/// tick must never cause the open `MenuBarExtra(.menu)` to rebuild and reset the user's hover).
@Suite("MenuBarMenuModel")
@MainActor
struct MenuBarMenuModelTests {
    @Test("starts with nil recordingTitle, empty hiddenWindows, and empty profiles")
    func startsEmpty() {
        let model = MenuBarMenuModel()
        #expect(model.content.recordingTitle == nil)
        #expect(model.content.hiddenWindows.isEmpty)
        #expect(model.content.profiles.isEmpty)
    }

    @Test("update(_:) with an unchanged value does not fire objectWillChange")
    func unchangedUpdateDoesNotPublish() {
        let model = MenuBarMenuModel()
        let content = MenuBarMenuContent(recordingTitle: "会議", hiddenWindows: [], profiles: [])
        model.update(content)

        var fired = false
        let cancellable = model.objectWillChange.sink { fired = true }
        model.update(content) // identical value: the §4.2 de-dup guard must suppress this.

        #expect(fired == false)
        #expect(model.content == content)
        cancellable.cancel()
    }

    @Test("update(_:) with a genuinely different value does fire objectWillChange")
    func changedUpdatePublishes() {
        let model = MenuBarMenuModel()
        model.update(MenuBarMenuContent(recordingTitle: "会議A", hiddenWindows: [], profiles: []))

        var fired = false
        let cancellable = model.objectWillChange.sink { fired = true }
        model.update(MenuBarMenuContent(recordingTitle: "会議B", hiddenWindows: [], profiles: []))

        #expect(fired == true)
        #expect(model.content.recordingTitle == "会議B")
        cancellable.cancel()
    }

    @Test("a run of timerText-only-driven MenuBarStatus updates (via derive) never publishes")
    func timerTickSequenceThroughDeriveNeverPublishes() {
        // Regression for §6 failure mode #15: simulates WindowManager.recomputeMenuBarStatus()'s
        // once-a-second call feeding MenuBarMenuContent.derive(from:profiles:) into this model while
        // only timerText changes across ticks.
        let model = MenuBarMenuModel()
        let recordingTitle = "デイリースクラム"
        model.update(MenuBarMenuContent.derive(
            from: MenuBarStatus(icon: .recording, timerText: "00:00", recordingTitle: recordingTitle, hiddenWindows: []),
            profiles: []
        ))

        var publishCount = 0
        let cancellable = model.objectWillChange.sink { publishCount += 1 }
        for second in 1 ... 5 {
            let ticked = MenuBarStatus(
                icon: .recording,
                timerText: TimeFormatting.clock(seconds: second),
                recordingTitle: recordingTitle,
                hiddenWindows: []
            )
            model.update(MenuBarMenuContent.derive(from: ticked, profiles: []))
        }

        #expect(publishCount == 0)
        cancellable.cancel()
    }

    // MARK: - profiles equality guard (docs/design/41-meeting-profiles.md §6.2)

    @Test("a run of derive(from:profiles:) calls with an unchanged profiles list never publishes, even as timerText ticks")
    func unchangedProfilesListThroughDeriveNeverPublishes() {
        let profiles = [MenuBarMenuContent.ProfileItem(id: "daily-scrum", name: "デイリースクラム")]
        let model = MenuBarMenuModel()
        model.update(MenuBarMenuContent.derive(
            from: MenuBarStatus(icon: .recording, timerText: "00:00", recordingTitle: "会議", hiddenWindows: []),
            profiles: profiles
        ))

        var publishCount = 0
        let cancellable = model.objectWillChange.sink { publishCount += 1 }
        for second in 1 ... 5 {
            let ticked = MenuBarStatus(
                icon: .recording,
                timerText: TimeFormatting.clock(seconds: second),
                recordingTitle: "会議",
                hiddenWindows: []
            )
            // The exact same `profiles` array instance/value every tick: WindowManager only calls
            // `refreshProfileMenu()` at its three defined points (§6.2), never once per second.
            model.update(MenuBarMenuContent.derive(from: ticked, profiles: profiles))
        }

        #expect(publishCount == 0)
        cancellable.cancel()
    }

    @Test("update(_:) fires objectWillChange when only the profiles list changes")
    func changedProfilesListPublishes() {
        let model = MenuBarMenuModel()
        model.update(MenuBarMenuContent.derive(from: .idle, profiles: []))

        var fired = false
        let cancellable = model.objectWillChange.sink { fired = true }
        model.update(MenuBarMenuContent.derive(
            from: .idle,
            profiles: [MenuBarMenuContent.ProfileItem(id: "daily-scrum", name: "デイリースクラム")]
        ))

        #expect(fired == true)
        #expect(model.content.profiles == [MenuBarMenuContent.ProfileItem(id: "daily-scrum", name: "デイリースクラム")])
        cancellable.cancel()
    }
}
