import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Kikimi

// MARK: - WindowCloseDecision

/// Unit tests for the pure decision table behind `windowShouldClose`
/// (`docs/design/06-ui-panels.md` section 6.1.1, `docs/design/18-recording-window-stow-and-compact.md`
/// §2 R2/R7's 3-value table). See `WindowCloseDecision`'s doc comment for why this logic is factored
/// out as a standalone, `NSWindow`-free enum.
@Suite("WindowCloseDecision")
struct WindowCloseDecisionTests {
    @Test("Draft/Ended (isStowable == false, blocksClose == false) allows the close")
    func allowsCloseWhenNeitherStowableNorBlocking() {
        #expect(WindowCloseDecision.evaluate(isStowable: false, blocksClose: false) == .allowClose)
    }

    @Test("recording/paused/pausedDisabledOtherRecording (isStowable == true) stows instead of closing")
    func stowsInsteadOfClosingWhenStowable() {
        #expect(WindowCloseDecision.evaluate(isStowable: true, blocksClose: true) == .stowInsteadOfClose)
    }

    @Test("isStowable takes priority over blocksClose even in the defensive combination where blocksClose is false")
    func isStowableTakesPriorityOverBlocksClose() {
        // Shouldn't occur in practice (`showsStowControls` is narrower than `blocksWindowClose`),
        // but the table must still resolve deterministically if it ever did.
        #expect(WindowCloseDecision.evaluate(isStowable: true, blocksClose: false) == .stowInsteadOfClose)
    }

    @Test("transitional states (starting/pausing/resuming/ending: isStowable == false, blocksClose == true) deny the close and do nothing")
    func deniesTransientStates() {
        #expect(WindowCloseDecision.evaluate(isStowable: false, blocksClose: true) == .denyTransient)
    }
}

// MARK: - MeetingEndReshowDecision

/// Unit tests for R6's "reveal the window when the meeting ends" judgment
/// (`docs/design/18-recording-window-stow-and-compact.md` §2/§5.1/§7), factored out of the
/// `viewModel.onMeetingEnded` closure so it's exercisable here without driving `WindowManager.shared`.
@Suite("MeetingEndReshowDecision")
struct MeetingEndReshowDecisionTests {
    @Test("never reshows a stowed window -- a window the user put away stays away, and would otherwise steal focus tens of seconds later when the confirmation processing finishes")
    func neverReshowsWhenStowed() {
        #expect(!MeetingEndReshowDecision.shouldReshow(isStowed: true, isCompact: false))
        #expect(!MeetingEndReshowDecision.shouldReshow(isStowed: true, isCompact: true))
    }

    @Test("expands a still-compact, non-stowed window back to normal -- it is already on screen, so no visibility/focus change happens")
    func reshowsWhenCompactAndNotStowed() {
        #expect(MeetingEndReshowDecision.shouldReshow(isStowed: false, isCompact: true))
    }

    @Test("does not reshow a window that is neither stowed nor compact -- an already-visible, normal window's endMeeting() (via the header's ⏹, or the menu bar's confirmed 会議を終了…) needs no reshow")
    func doesNotReshowWhenNeitherStowedNorCompact() {
        #expect(!MeetingEndReshowDecision.shouldReshow(isStowed: false, isCompact: false))
    }
}

// MARK: - MeetingWorkspaceWindowController

/// Unit tests for `MeetingWorkspaceWindowController`. Scoped to what's safely exercisable without
/// a real window server or the full recording stack (`AudioCapture`/`TranscriptPipeline`):
///
/// - `windowShouldClose` for a Draft session (never touches the confirmation dialog, since
///   `.startRecording` doesn't block closing) -- forcing `recordingButtonState` into `.recording`
///   would require driving `startRecording()`'s real `AudioCapture`/`TranscriptPipeline` sequence,
///   which is `MeetingWorkspaceViewModel`'s own testing surface (`docs/design/06-ui-panels.md`
///   section 12), not this controller's. `WindowCloseDecision`'s full 3-value table is instead
///   covered exhaustively, decision-table-only, above.
/// - `windowDidMove`/`windowDidResize`'s debounced persistence to an injected, temp-directory-backed
///   `AppState` (section 9).
/// - `stow()`/`unstow()`/`applyWindowMode(_:)` directly (`docs/design/18-recording-window-stow-and
///   -compact.md` §7), including `stow()`'s compact -> normal expansion (§3.2 step 0).
///
/// Deliberately **not** covered here: `windowShouldClose`'s `.stowInsteadOfClose` branch's call to
/// `WindowManager.shared.stowWorkspaceWindow(sessionId:)`, and `windowWillClose`'s call to
/// `WindowManager.shared.workspaceWindowDidClose(sessionId:)` (`06-ui-panels.md` section 5.2/9).
/// `WindowManager` is a hard-wired singleton with no test seam (by design: it's the app-wide
/// orchestrator, not a per-window dependency), and it forwards to `AppState.shared` -- the *real*
/// `~/.local/state/kikimi/state.yaml`, not the temp-directory instance these tests inject elsewhere.
/// Exercising it here would leak test session ids into the developer's actual state file. That
/// interaction is instead verified end-to-end by the `kikimi-verify` skill (section 12, layer 2).
@Suite("MeetingWorkspaceWindowController")
@MainActor
struct MeetingWorkspaceWindowControllerTests {
    private func makeTempDirectory(prefix: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Polls `condition` until it becomes `true` or `timeout` elapses, instead of a single fixed
    /// `Task.sleep` margin. The debounced-save tests below only need a handful of milliseconds in
    /// the common case, but a fixed ~10x margin proved flaky under heavy parallel test load (e.g.
    /// while `TranscriptPipeline integration`'s real STT inference is also running): the
    /// `@MainActor`-hopping `Task.sleep` inside `scheduleWindowStateSave()` can overrun a fixed
    /// wait by well more than 10x when the main actor's serial executor is contended. Mirrors
    /// `MeetingWorkspaceViewModelTests.waitUntil(timeout:condition:)`'s same rationale.
    private func waitUntil(
        timeout: Duration = .seconds(10),
        condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for condition to become true")
    }

    private func baseMeta(id: String) -> SessionMeta {
        SessionMeta(
            id: id,
            title: "Test Session",
            titleAutoGenerated: true,
            titleAutoNamedOnce: false,
            titleProposal: nil,
            state: .draft,
            createdAt: Date(timeIntervalSince1970: 1_751_000_000),
            startedAt: nil,
            endedAt: nil,
            durationMs: 0,
            basedOnSession: nil,
            segmentCount: 0,
            refinedCount: 0,
            appVersion: "0.1.0"
        )
    }

    /// Builds a controller wired to a freshly-created, still-`.draft` session (so
    /// `recordingButtonState` starts as `.startRecording`, which never blocks closing) and a
    /// temp-directory-backed `AppState` instead of the real `~/.local/state/kikimi/state.yaml`.
    private func makeController(sessionId: String, appState: AppState) -> MeetingWorkspaceWindowController {
        let sessionDirectory = makeTempDirectory(prefix: "MeetingWorkspaceWindowControllerTests-session")
        let handle = SessionHandle(directoryURL: sessionDirectory, meta: baseMeta(id: sessionId))
        let viewModel = MeetingWorkspaceViewModel(sessionHandle: handle)
        return MeetingWorkspaceWindowController(viewModel: viewModel, appState: appState)
    }

    // MARK: - Restoration (section 5.1: saved frame + activeTab)

    @Test("init restores the saved frame, activeTab, and meetingPaneMode from AppState, keyed by sessionId")
    func initRestoresSavedFrameAndActiveTab() throws {
        let appState = AppState(directory: makeTempDirectory(prefix: "MeetingWorkspaceWindowControllerTests-state"))
        appState.upsertWindowState(
            WorkspaceWindowState(
                sessionId: "session-restore",
                x: 42,
                y: 84,
                width: 640,
                height: 480,
                visible: true,
                activeTab: .meeting,
                meetingPaneMode: .transcript
            )
        )

        let controller = makeController(sessionId: "session-restore", appState: appState)

        let window = try #require(controller.window)
        #expect(window.frame.origin.x == 42)
        #expect(window.frame.origin.y == 84)
        #expect(window.frame.width == 640)
        #expect(window.frame.height == 480)
        #expect(controller.viewModel.activeTab == .meeting)
        #expect(controller.viewModel.meetingPaneMode == .transcript)
    }

    @Test("init falls back to the default frame and leaves activeTab/meetingPaneMode untouched when there's no saved state")
    func initFallsBackToDefaultsWhenNoSavedState() throws {
        let appState = AppState(directory: makeTempDirectory(prefix: "MeetingWorkspaceWindowControllerTests-state"))
        let sessionDirectory = makeTempDirectory(prefix: "MeetingWorkspaceWindowControllerTests-session")
        let handle = SessionHandle(directoryURL: sessionDirectory, meta: baseMeta(id: "session-no-saved-state"))
        let viewModel = MeetingWorkspaceViewModel(sessionHandle: handle)
        // Captured before wrapping in a controller: whatever the view model's own default is, the
        // controller must not overwrite it when `AppState` has no saved entry for this session yet.
        let activeTabBeforeRestoration = viewModel.activeTab
        let meetingPaneModeBeforeRestoration = viewModel.meetingPaneMode

        let controller = MeetingWorkspaceWindowController(viewModel: viewModel, appState: appState)

        let window = try #require(controller.window)
        #expect(window.frame.origin.x == 100)
        #expect(window.frame.origin.y == 100)
        #expect(window.frame.width == 800)
        #expect(window.frame.height == 600)
        #expect(controller.viewModel.activeTab == activeTabBeforeRestoration)
        #expect(controller.viewModel.meetingPaneMode == meetingPaneModeBeforeRestoration)
    }

    // MARK: - windowShouldClose

    @Test("a freshly-loaded Draft session's window closes immediately (allowClose: not stowable, not blocking)")
    func draftSessionClosesImmediately() throws {
        let appState = AppState(directory: makeTempDirectory(prefix: "MeetingWorkspaceWindowControllerTests-state"))
        let controller = makeController(sessionId: "session-draft", appState: appState)

        let window = try #require(controller.window)

        #expect(controller.windowShouldClose(window))
    }

    // MARK: - Position/size persistence (section 9)

    @Test("windowDidMove persists the window frame and meetingPaneMode to AppState after the debounce interval, keyed by sessionId")
    func moveAndResizePersistFrameAfterDebounce() async throws {
        let appState = AppState(directory: makeTempDirectory(prefix: "MeetingWorkspaceWindowControllerTests-state"))
        let controller = makeController(sessionId: "session-move", appState: appState)
        controller.moveResizeDebounceNanoseconds = 5_000_000 // 5ms, so the test doesn't wait the real 300ms
        // `docs/design/17-session-window-redesign.md` §4.2: saved alongside activeTab.
        controller.viewModel.meetingPaneMode = .summary

        let window = try #require(controller.window)
        window.setFrame(NSRect(x: 42, y: 84, width: 640, height: 480), display: false)

        controller.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: window))
        try await waitUntil { appState.windowState(for: "session-move") != nil }

        // The frame is read back and converted explicitly: `#expect` compares a `Double` against a
        // `CGFloat` as *false* even when the two are bit-identical, so the conversion is load-bearing,
        // not cosmetic. Compared against `window.frame` rather than the requested rect because the
        // subject here is "the debounced save persists whatever frame the window has" -- the window
        // server may have adjusted the request to fit the host screen
        // (`.requiresUnconstrainedWindowGeometry`'s doc comment).
        let saved = try #require(appState.windowState(for: "session-move"))
        let frame = window.frame
        #expect(saved.sessionId == "session-move")
        #expect(saved.x == Double(frame.origin.x))
        #expect(saved.y == Double(frame.origin.y))
        #expect(saved.width == Double(frame.width))
        #expect(saved.height == Double(frame.height))
        #expect(saved.visible == window.isVisible)
        #expect(saved.meetingPaneMode == .summary)
    }

    @Test("rapid successive windowDidMove calls coalesce into a single AppState write, not one per event")
    func rapidMovesCoalesceIntoOneWrite() async throws {
        let appState = AppState(directory: makeTempDirectory(prefix: "MeetingWorkspaceWindowControllerTests-state"))
        let controller = makeController(sessionId: "session-coalesce", appState: appState)
        controller.moveResizeDebounceNanoseconds = 40_000_000 // 40ms

        let window = try #require(controller.window)

        for step in 1...5 {
            window.setFrame(NSRect(x: CGFloat(step * 10), y: 0, width: 800, height: 600), display: false)
            controller.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: window))
            try await Task.sleep(nanoseconds: 10_000_000) // well within the 40ms debounce window: keeps restarting it
        }

        // Nothing should have been persisted yet: every move restarted the debounce timer before it fired.
        #expect(appState.windowState(for: "session-coalesce") == nil)

        try await waitUntil { appState.windowState(for: "session-coalesce") != nil } // let the final debounce actually fire

        // Only the final frame (x: 50, from step 5) should have made it to disk.
        let saved = try #require(appState.windowState(for: "session-coalesce"))
        #expect(saved.x == 50)
    }

    @Test("windowDidResize persists the window frame the same way windowDidMove does")
    func resizePersistsFrameAfterDebounce() async throws {
        let appState = AppState(directory: makeTempDirectory(prefix: "MeetingWorkspaceWindowControllerTests-state"))
        let controller = makeController(sessionId: "session-resize", appState: appState)
        controller.moveResizeDebounceNanoseconds = 5_000_000 // 5ms

        let window = try #require(controller.window)
        window.setFrame(NSRect(x: 10, y: 20, width: 900, height: 700), display: false)

        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
        try await waitUntil { appState.windowState(for: "session-resize") != nil }

        let saved = try #require(appState.windowState(for: "session-resize"))
        #expect(saved.width == Double(window.frame.width))
        #expect(saved.height == Double(window.frame.height))
    }

    // MARK: - しまう: stow()/unstow() (`docs/design/18-recording-window-stow-and-compact.md` §3.2/§5.2/§7)

    @Test("stow() orders the window out, flips AppState visible to false, and leaves the view model/window alive")
    func stowOrdersOutAndMarksHidden() throws {
        let appState = AppState(directory: makeTempDirectory(prefix: "MeetingWorkspaceWindowControllerTests-state"))
        // §4.3: markWindowHidden() only flips an *existing* entry's visible field -- seed one first,
        // matching the "already saved at least once" case a real Recording/Paused window would have.
        appState.upsertWindowState(
            WorkspaceWindowState(
                sessionId: "session-stow", x: 42, y: 84, width: 640, height: 480,
                visible: true, activeTab: .meeting, meetingPaneMode: .both
            )
        )
        let controller = makeController(sessionId: "session-stow", appState: appState)
        let viewModel = controller.viewModel

        controller.stow()

        // (a) The controller/view model survive `stow()` -- it is emphatically not `close()`
        // (§3.2 R1): the same view model instance is still reachable, and the window itself is
        // still around (merely ordered out), not deallocated.
        #expect(controller.viewModel === viewModel)
        #expect(controller.window != nil)
        #expect(controller.window?.isVisible == false)

        // (b) AppState's visible flag flips to false; the rest of the entry (frame/tab/pane mode)
        // is untouched by stow() itself.
        let saved = try #require(appState.windowState(for: "session-stow"))
        #expect(saved.visible == false)
        #expect(saved.x == 42)
        #expect(saved.y == 84)
        #expect(saved.activeTab == .meeting)
        #expect(saved.meetingPaneMode == .both)
    }

    @Test("stow() cancels any in-flight debounced save so it never lands afterward (§6 failure mode #8)")
    func stowCancelsInFlightDebouncedSave() async throws {
        // Deliberately no pre-seeded entry: `markWindowHidden()` is a no-op when no entry exists yet
        // (§4.3), so if the cancellation didn't happen, the *only* way an entry could ever appear
        // here is the stale debounced `saveWindowState()` call actually firing and creating one via
        // `upsertWindowState`'s insert branch.
        let appState = AppState(directory: makeTempDirectory(prefix: "MeetingWorkspaceWindowControllerTests-state"))
        let controller = makeController(sessionId: "session-stow-debounce", appState: appState)
        controller.moveResizeDebounceNanoseconds = 30_000_000 // 30ms

        let window = try #require(controller.window)
        window.setFrame(NSRect(x: 1, y: 2, width: 3, height: 4), display: false)
        controller.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: window))

        // Stow well before the 30ms debounce would fire.
        controller.stow()

        // Wait comfortably past the original debounce window. If the task hadn't been cancelled,
        // it would have fired by now and created an entry.
        try await Task.sleep(nanoseconds: 150_000_000) // 150ms
        #expect(appState.windowState(for: "session-stow-debounce") == nil)
    }

    @Test("stow() while compact expands back to normal (applyWindowMode(.normal)) before ordering out (§3.2 step 0)", .requiresUnconstrainedWindowGeometry)
    func stowWhileCompactExpandsToNormalFirst() async throws {
        let appState = AppState(directory: makeTempDirectory(prefix: "MeetingWorkspaceWindowControllerTests-state"))
        let controller = makeController(sessionId: "session-stow-while-compact", appState: appState)
        let window = try #require(controller.window)
        window.setFrame(NSRect(x: 30, y: 40, width: 800, height: 600), display: false)
        let expandedFrame = window.frame

        controller.viewModel.windowMode = .compact
        try await waitUntil { window.frame.width == 380 && window.frame.height == 44 }

        controller.stow()

        // The invariant §3.2 step 0 exists to uphold: "しまってある間はモード不変・再表示は常に通常表示"
        // -- windowMode is back to .normal and the frame is the pre-compact expanded one, not the pill.
        #expect(controller.viewModel.windowMode == .normal)
        #expect(window.frame.origin.x == expandedFrame.origin.x)
        #expect(window.frame.origin.y == expandedFrame.origin.y)
        #expect(window.frame.width == expandedFrame.width)
        #expect(window.frame.height == expandedFrame.height)
        // ...and it's still actually hidden -- expanding first must not skip the orderOut itself.
        #expect(window.isVisible == false)
    }

    @Test("unstow() on an existing AppState entry updates visible to true, leaving frame/tab/paneMode as they currently are")
    func unstowOnExistingEntryUpdatesVisibleOnly() throws {
        let appState = AppState(directory: makeTempDirectory(prefix: "MeetingWorkspaceWindowControllerTests-state"))
        appState.upsertWindowState(
            WorkspaceWindowState(
                sessionId: "session-unstow-existing", x: 55, y: 66, width: 700, height: 500,
                visible: false, activeTab: .watchers, meetingPaneMode: .transcript
            )
        )
        let controller = makeController(sessionId: "session-unstow-existing", appState: appState)
        // The controller restored these from the saved entry above (init's restoration path);
        // confirm the premise before unstow() so the "unchanged" assertion below is meaningful.
        #expect(controller.viewModel.activeTab == .watchers)
        #expect(controller.viewModel.meetingPaneMode == .transcript)

        controller.unstow()

        let saved = try #require(appState.windowState(for: "session-unstow-existing"))
        #expect(saved.visible == true)
        #expect(saved.x == 55)
        #expect(saved.y == 66)
        #expect(saved.width == 700)
        #expect(saved.height == 500)
        #expect(saved.activeTab == .watchers)
        #expect(saved.meetingPaneMode == .transcript)
    }

    @Test("unstow() with no existing AppState entry creates a full new entry from the window's current frame/activeTab/meetingPaneMode")
    func unstowWithNoExistingEntryCreatesFullEntry() throws {
        let appState = AppState(directory: makeTempDirectory(prefix: "MeetingWorkspaceWindowControllerTests-state"))
        let controller = makeController(sessionId: "session-unstow-new", appState: appState)
        #expect(appState.windowState(for: "session-unstow-new") == nil)

        controller.unstow()

        let saved = try #require(appState.windowState(for: "session-unstow-new"))
        #expect(saved.visible == true)
        // `makeController`'s freshly-created Draft session has no saved state, so the controller's
        // init fell back to `defaultFrame` (100, 100, 800, 600) and the view model's own defaults.
        #expect(saved.x == 100)
        #expect(saved.y == 100)
        #expect(saved.width == 800)
        #expect(saved.height == 600)
        #expect(saved.activeTab == controller.viewModel.activeTab)
        #expect(saved.meetingPaneMode == controller.viewModel.meetingPaneMode)
    }

    @Test("unstow() while compact does not persist the pill frame -- it upserts the pre-compact expanded frame instead (Minor-1 fix, §4.3/R5)")
    func unstowWhileCompactPersistsExpandedFrameNotPillFrame() throws {
        let appState = AppState(directory: makeTempDirectory(prefix: "MeetingWorkspaceWindowControllerTests-state"))
        let controller = makeController(sessionId: "session-unstow-compact-new-entry", appState: appState)
        let window = try #require(controller.window)
        window.setFrame(NSRect(x: 30, y: 40, width: 800, height: 600), display: false)
        // `#expect(_ == _)`'s diagnostic-capturing macro expansion doesn't bridge `Double`
        // (`WorkspaceWindowState`'s fields) and `CGFloat` (`NSRect`'s) as equal even when the
        // underlying values are bit-identical, so every frame component is normalized to `Double`
        // up front rather than comparing `saved.x == window.frame.origin.x` directly.
        let expandedX = Double(window.frame.origin.x)
        let expandedY = Double(window.frame.origin.y)
        let expandedWidth = Double(window.frame.width)
        let expandedHeight = Double(window.frame.height)

        controller.viewModel.windowMode = .compact
        // Premise: compacting alone still doesn't write anything (R5's existing guard, unchanged).
        #expect(appState.windowState(for: "session-unstow-compact-new-entry") == nil)

        controller.unstow()

        let saved = try #require(appState.windowState(for: "session-unstow-compact-new-entry"))
        #expect(saved.visible == true)
        // The pre-compact expanded frame was persisted, not the current (pill-sized) window frame.
        #expect(saved.x == expandedX)
        #expect(saved.y == expandedY)
        #expect(saved.width == expandedWidth)
        #expect(saved.height == expandedHeight)
        #expect(saved.width != 380)
        #expect(saved.height != 44)
    }

    @Test("unstow() while compact, on an existing AppState entry, flips visible to true without ever writing the pill frame")
    func unstowWhileCompactOnExistingEntryUpdatesVisibleWithoutPillFrame() throws {
        let appState = AppState(directory: makeTempDirectory(prefix: "MeetingWorkspaceWindowControllerTests-state"))
        appState.upsertWindowState(
            WorkspaceWindowState(
                sessionId: "session-unstow-compact-existing", x: 55, y: 66, width: 700, height: 500,
                visible: false, activeTab: .watchers, meetingPaneMode: .transcript
            )
        )
        let controller = makeController(sessionId: "session-unstow-compact-existing", appState: appState)
        let window = try #require(controller.window)
        // Restored from the saved entry above (700x500 @ 55,66); see the `Double` normalization note
        // in `unstowWhileCompactPersistsExpandedFrameNotPillFrame` above.
        let expandedX = Double(window.frame.origin.x)
        let expandedY = Double(window.frame.origin.y)
        let expandedWidth = Double(window.frame.width)
        let expandedHeight = Double(window.frame.height)

        controller.viewModel.windowMode = .compact

        controller.unstow()

        let saved = try #require(appState.windowState(for: "session-unstow-compact-existing"))
        #expect(saved.visible == true)
        #expect(saved.x == expandedX)
        #expect(saved.y == expandedY)
        #expect(saved.width == expandedWidth)
        #expect(saved.height == expandedHeight)
        #expect(saved.width != 380)
        #expect(saved.height != 44)
    }

    // MARK: - コンパクトモード: applyWindowMode (`docs/design/18-recording-window-stow-and-compact.md` §5.2/§7)

    @Test("setting viewModel.windowMode = .compact then back to .normal restores the pre-compact frame", .requiresUnconstrainedWindowGeometry)
    func compactThenNormalRestoresExpandedFrame() async throws {
        let appState = AppState(directory: makeTempDirectory(prefix: "MeetingWorkspaceWindowControllerTests-state"))
        let controller = makeController(sessionId: "session-compact-roundtrip", appState: appState)
        let window = try #require(controller.window)
        window.setFrame(NSRect(x: 30, y: 40, width: 800, height: 600), display: false)
        let expandedFrame = window.frame

        controller.viewModel.windowMode = .compact
        // `applyCompactMode()`'s actual `setFrame` to the 380x44 pill is deferred one main-run-loop
        // turn (`resizeToPillFrameAfterSwiftUIReconciles`'s doc comment) so the real app's SwiftUI
        // re-render onto `CompactRecordingBarView` lands before the window is asked to shrink --
        // poll instead of asserting immediately, matching `waitUntil`'s existing debounce-test usage.
        try await waitUntil { window.frame.width == 380 && window.frame.height == 44 }
        // §3.4: fixed 380x44 pill, left edge/top edge held fixed from the pre-compact frame.
        #expect(window.frame.width == 380)
        #expect(window.frame.height == 44)
        #expect(window.frame.origin.x == expandedFrame.origin.x)
        #expect(window.frame.maxY == expandedFrame.maxY)

        controller.viewModel.windowMode = .normal
        #expect(window.frame.origin.x == expandedFrame.origin.x)
        #expect(window.frame.origin.y == expandedFrame.origin.y)
        #expect(window.frame.width == expandedFrame.width)
        #expect(window.frame.height == expandedFrame.height)
    }

    @Test("while compact, both scheduleWindowStateSave (windowDidMove/Resize) and the debounced saveWindowState it would have scheduled are no-ops (R5's double guard)")
    func compactModeSuppressesBothMoveResizeSchedulingAndDebouncedSave() async throws {
        let appState = AppState(directory: makeTempDirectory(prefix: "MeetingWorkspaceWindowControllerTests-state"))
        let controller = makeController(sessionId: "session-compact-noop", appState: appState)
        controller.moveResizeDebounceNanoseconds = 20_000_000 // 20ms
        let window = try #require(controller.window)

        controller.viewModel.windowMode = .compact
        // Simulate a drag/resize while compact (e.g. the pill being dragged around).
        controller.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: window))
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))

        try await Task.sleep(nanoseconds: 100_000_000) // well past the 20ms debounce
        #expect(appState.windowState(for: "session-compact-noop") == nil)
    }

    @Test("no pill frame is ever persisted after compacting, even once the move/resize debounce would have elapsed (§5.2 B2 regression)")
    func compactModeNeverPersistsThePillFrame() async throws {
        let appState = AppState(directory: makeTempDirectory(prefix: "MeetingWorkspaceWindowControllerTests-state"))
        let controller = makeController(sessionId: "session-compact-pill-leak", appState: appState)
        controller.moveResizeDebounceNanoseconds = 20_000_000 // 20ms

        controller.viewModel.windowMode = .compact

        // Wait past the debounce window entirely off of any explicit windowDidMove/Resize call --
        // this reproduces the exact ordering bug the doc comment on `applyCompactMode()` describes:
        // `setFrame` itself synchronously triggers `windowDidResize`, which must be guarded by
        // `isCompact` having already flipped `true` *before* that call.
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(appState.windowState(for: "session-compact-pill-leak") == nil)
    }

    @Test("the initial replay of $windowMode (already .normal) at init time does not trigger saveWindowState")
    func initialWindowModeReplayDoesNotTriggerSave() throws {
        let appState = AppState(directory: makeTempDirectory(prefix: "MeetingWorkspaceWindowControllerTests-state"))
        // Constructing the controller alone (no explicit move/resize/mode change) must not write
        // anything to AppState -- if `.dropFirst()` were missing from the `$windowMode` subscription,
        // the replayed initial `.normal` value would run `applyWindowMode(.normal)`, whose trailing
        // `saveWindowState()` would upsert a premature entry before `showWindow(nil)` is even called.
        _ = makeController(sessionId: "session-initial-replay", appState: appState)
        #expect(appState.windowState(for: "session-initial-replay") == nil)
    }

    @Test("re-assigning viewModel.windowMode = .normal while already .normal is a no-op (removeDuplicates)")
    func reassigningSameWindowModeIsANoOp() throws {
        let appState = AppState(directory: makeTempDirectory(prefix: "MeetingWorkspaceWindowControllerTests-state"))
        let controller = makeController(sessionId: "session-same-mode-noop", appState: appState)

        controller.viewModel.windowMode = .normal // already .normal; must not trigger applyWindowMode
        #expect(appState.windowState(for: "session-same-mode-noop") == nil)
    }

    // MARK: - `NSHostingView.sizingOptions` (real-window regression for the 484x179/+11pt bugs)

    /// `NSHostingView`'s default `sizingOptions` (`[.minSize, .intrinsicContentSize, .maxSize]`,
    /// macOS 13+) makes the hosting view impose Auto Layout constraints derived from its SwiftUI
    /// content's ideal/min/max size back onto the window -- which is exactly what was overriding
    /// this controller's manual `setFrame` calls in both directions (`applyCompactMode()`'s pill
    /// inflating past 380x44, and `applyNormalMode()`'s restored frame drifting +11pt taller than
    /// what was actually saved). `compactThenNormalRestoresExpandedFrame` above can't catch this on
    /// its own: XCTest/swift-testing's off-screen `NSWindow` never actually runs a real Auto Layout
    /// pass the way the on-screen `kikimi-verify` repro did, so it happily reports the frame this
    /// controller *asked for* rather than the frame `NSHostingView`'s constraints would have fought
    /// it back to on a real window server. This test instead asserts the fix directly: the one
    /// property (`sizingOptions == []`) whose absence is what let that fight happen at all.
    @Test("the window's content view has sizingOptions disabled, so NSHostingView never fights this controller's manual setFrame calls")
    func hostingViewSizingOptionsAreDisabled() throws {
        let appState = AppState(directory: makeTempDirectory(prefix: "MeetingWorkspaceWindowControllerTests-state"))
        let controller = makeController(sessionId: "session-sizing-options", appState: appState)

        let window = try #require(controller.window)
        let hostingView = try #require(window.contentView as? NSHostingView<MeetingWorkspaceView>)
        #expect(hostingView.sizingOptions == [])
    }
}
