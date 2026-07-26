import AppKit
import Foundation
import Testing

@testable import Kikimi

// MARK: - DictationHistoryWindowController

/// Unit tests for `DictationHistoryWindowController` (`docs/design/29-dictation-history.md` section
/// 6.1, DH8). Scoped to what's safely exercisable without driving a real window server or touching
/// the developer's actual `~/.local/state/kikimi/state.yaml`:
///
/// - `init`'s frame restoration from an injected `AppState`, including the `640x420` minimum-size
///   clamp described by the controller's own `minimumSize` doc comment.
/// - `windowDidMove`/`windowDidResize`'s debounced persistence to `AppState.dictationHistoryWindow`
///   (mirroring `MeetingWorkspaceWindowControllerTests`'s own move/resize debounce tests).
/// - `windowWillClose`'s "flush the pending debounce immediately, then persist `visible: false`"
///   sequence.
///
/// Deliberately **not** covered here: `show()`'s `NSApp.activate(ignoringOtherApps:)` call. No
/// existing window controller test suite calls `.show()` for exactly this reason (it would steal
/// focus from whatever the developer/CI runner is doing); `show()`'s sole non-AppKit side effect
/// (`persistVisibility(true)`) is trivial and shares the same `updateDictationHistoryWindow` code
/// path already verified via `windowWillClose`'s `persistVisibility(false)` below.
@Suite("DictationHistoryWindowController")
@MainActor
struct DictationHistoryWindowControllerTests {
    private func makeTempDirectory(prefix: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeAppState() -> AppState {
        AppState(directory: makeTempDirectory(prefix: "DictationHistoryWindowControllerTests-state"))
    }

    /// Polls `condition` until it becomes `true` or `timeout` elapses, matching
    /// `MeetingWorkspaceWindowControllerTests.waitUntil`'s own rationale (a fixed sleep proved
    /// flaky under contended CI/parallel-test load). The timeout is only a hang guard, so it is
    /// deliberately far longer than any debounce interval these tests configure: the debounced save
    /// hops through the main queue, and on a loaded CI runner sharing few cores with 1,900 other
    /// tests, that hop alone overran the previous 2s ceiling.
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

    // MARK: - init frame restoration (section 6.1)

    @Test("init restores the saved frame from AppState as-is when it already meets the view's 640x420 minimum", .requiresUnconstrainedWindowGeometry)
    func initRestoresSavedFrameAboveMinimum() throws {
        let appState = makeAppState()
        appState.updateDictationHistoryWindow { state in
            state.x = 10
            state.y = 20
            state.width = 800
            state.height = 600
            state.visible = true
        }

        let controller = DictationHistoryWindowController(appState: appState)

        let window = try #require(controller.window)
        #expect(window.frame.origin.x == 10)
        #expect(window.frame.origin.y == 20)
        #expect(window.frame.width == 800)
        #expect(window.frame.height == 600)
    }

    @Test("init clamps width/height up to the 640x420 minimum when the saved state is smaller, leaving the saved origin untouched", .requiresUnconstrainedWindowGeometry)
    func initClampsUndersizedSavedFrameToMinimum() throws {
        let appState = makeAppState()
        appState.updateDictationHistoryWindow { state in
            state.x = 5
            state.y = 6
            state.width = 300
            state.height = 200
        }

        let controller = DictationHistoryWindowController(appState: appState)

        let window = try #require(controller.window)
        #expect(window.frame.origin.x == 5)
        #expect(window.frame.origin.y == 6)
        #expect(window.frame.width == 640)
        #expect(window.frame.height == 420)
    }

    @Test("init falls back to FloatingWindowState.default's origin, clamped to the 640x420 minimum, when there is no saved state", .requiresUnconstrainedWindowGeometry)
    func initFallsBackToDefaultClampedToMinimum() throws {
        let appState = makeAppState()

        let controller = DictationHistoryWindowController(appState: appState)

        let window = try #require(controller.window)
        // `FloatingWindowState.default` is (100, 750, 500, 400) -- shared with `sessionListWindow`
        // and sized for `SessionListWindowController`'s smaller 480x360 minimum, so width/height get
        // clamped up here while the origin passes through unchanged.
        #expect(window.frame.origin.x == 100)
        #expect(window.frame.origin.y == 750)
        #expect(window.frame.width == 640)
        #expect(window.frame.height == 420)
    }

    @Test("init sets the window title and minimum size")
    func initSetsTitleAndMinimumSize() throws {
        let controller = DictationHistoryWindowController(appState: makeAppState())

        let window = try #require(controller.window)
        #expect(window.title == "ディクテーション履歴")
        #expect(window.minSize.width == 640)
        #expect(window.minSize.height == 420)
    }

    // MARK: - Position/size persistence (section 6.1)

    @Test("windowDidMove persists the window frame to AppState after the debounce interval")
    func moveAndResizePersistFrameAfterDebounce() async throws {
        let appState = makeAppState()
        let controller = DictationHistoryWindowController(appState: appState)
        controller.frameSaveDebounceInterval = 0.005 // 5ms, so the test doesn't wait the real 300ms

        let window = try #require(controller.window)
        window.setFrame(NSRect(x: 42, y: 84, width: 700, height: 500), display: false)

        controller.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: window))
        try await waitUntil { appState.data.dictationHistoryWindow.x == 42 }

        // The frame is read back and converted explicitly: `#expect` compares a `Double` against a
        // `CGFloat` as *false* even when the two are bit-identical, so the conversion is load-bearing,
        // not cosmetic. Compared against `window.frame` rather than the requested rect because the
        // subject here is "the debounced save persists whatever frame the window has" -- the window
        // server may have adjusted the request to fit the host screen
        // (`.requiresUnconstrainedWindowGeometry`'s doc comment).
        let saved = appState.data.dictationHistoryWindow
        let frame = window.frame
        #expect(saved.x == Double(frame.origin.x))
        #expect(saved.y == Double(frame.origin.y))
        #expect(saved.width == Double(frame.width))
        #expect(saved.height == Double(frame.height))
    }

    @Test("windowDidResize persists the window frame the same way windowDidMove does")
    func resizePersistsFrameAfterDebounce() async throws {
        let appState = makeAppState()
        let controller = DictationHistoryWindowController(appState: appState)
        controller.frameSaveDebounceInterval = 0.005

        let window = try #require(controller.window)
        window.setFrame(NSRect(x: 10, y: 20, width: 900, height: 700), display: false)

        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
        try await waitUntil { appState.data.dictationHistoryWindow.width == 900 }

        let saved = appState.data.dictationHistoryWindow
        #expect(saved.width == Double(window.frame.width))
        #expect(saved.height == Double(window.frame.height))
    }

    @Test("rapid successive windowDidMove calls coalesce into a single AppState write, not one per event")
    func rapidMovesCoalesceIntoOneWrite() async throws {
        let appState = makeAppState()
        let controller = DictationHistoryWindowController(appState: appState)
        controller.frameSaveDebounceInterval = 0.04 // 40ms

        let window = try #require(controller.window)

        // No awaits inside the loop: the debounced work items are queued on the main queue, and
        // this @MainActor test never yields to it until the waitUntil below, so "no premature
        // write" is deterministic rather than a race against the 40ms timer under CI load.
        // (`setFrame` also fires the real delegate `windowDidMove` synchronously; that just
        // restarts the same debounce and is exactly the coalescing under test.)
        for step in 1...5 {
            window.setFrame(NSRect(x: CGFloat(step * 10), y: 0, width: 800, height: 600), display: false)
            controller.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: window))
        }

        // Nothing can have landed yet -- the main queue hasn't been drained since the first move.
        // `FloatingWindowState.default.x` is 100, so a premature write would show up as something
        // other than that (and not yet 50, the final step's value).
        #expect(appState.data.dictationHistoryWindow.x == FloatingWindowState.default.x)

        try await waitUntil { appState.data.dictationHistoryWindow.x == 50 } // let the final debounce actually fire

        #expect(appState.data.dictationHistoryWindow.x == 50)
    }

    // MARK: - windowWillClose (section 6.1)

    @Test("windowWillClose flushes a pending debounced frame save immediately, without waiting out the debounce")
    func windowWillCloseFlushesPendingSaveImmediately() throws {
        let appState = makeAppState()
        let controller = DictationHistoryWindowController(appState: appState)
        // Deliberately long, so if the flush didn't happen synchronously the assertion below would
        // still see the pre-move value.
        controller.frameSaveDebounceInterval = 10

        let window = try #require(controller.window)
        window.setFrame(NSRect(x: 77, y: 88, width: 700, height: 500), display: false)
        controller.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: window))

        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))

        let saved = appState.data.dictationHistoryWindow
        #expect(saved.x == 77)
        #expect(saved.y == 88)
        #expect(saved.width == 700)
        #expect(saved.height == 500)
    }

    @Test("windowWillClose persists visible = false")
    func windowWillClosePersistsVisibleFalse() throws {
        let appState = makeAppState()
        appState.updateDictationHistoryWindow { state in
            state.visible = true
        }
        let controller = DictationHistoryWindowController(appState: appState)
        let window = try #require(controller.window)

        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))

        #expect(appState.data.dictationHistoryWindow.visible == false)
    }

    @Test("windowWillClose cancels the pending debounce so the stale save never lands afterward")
    func windowWillCloseCancelsPendingDebounce() async throws {
        let appState = makeAppState()
        let controller = DictationHistoryWindowController(appState: appState)
        controller.frameSaveDebounceInterval = 0.03 // 30ms

        let window = try #require(controller.window)
        window.setFrame(NSRect(x: 1, y: 2, width: 640, height: 420), display: false)
        controller.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: window))

        // windowWillClose's own immediate saveFrame() already writes this exact frame, so move the
        // window again post-close to a value that would only appear if the *cancelled* debounce had
        // gone on to fire late (saveFrame reads the window's *current* frame at fire time, so a
        // non-cancelled work item would persist 999). Detach the delegate first: `setFrame` fires
        // the real `windowDidMove` synchronously through AppKit, which would otherwise schedule a
        // fresh, legitimate save of (999, 999) and make the assertion test the wrong thing.
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
        window.delegate = nil
        window.setFrame(NSRect(x: 999, y: 999, width: 640, height: 420), display: false)

        // Wait comfortably past the original 30ms debounce. The cancelled work item must never
        // fire; if it did, it would save the current (999, 999) frame over windowWillClose's own
        // (1, 2) write.
        try await Task.sleep(for: .milliseconds(100))
        let saved = appState.data.dictationHistoryWindow
        #expect(saved.x == 1)
        #expect(saved.y == 2)
    }
}
