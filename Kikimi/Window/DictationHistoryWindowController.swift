import AppKit
import OSLog
import SwiftUI

// MARK: - DictationHistoryWindowController

/// Owns the single Dictation History window (`docs/design/29-dictation-history.md` section 6.1,
/// DH8). A floating `.nonactivatingPanel` embedding the history list/detail content via
/// `NSHostingView`, modeled directly on `SessionListWindowController` (see that file's doc
/// comment): a single long-lived panel that is shown/hidden rather than recreated per use, with
/// frame/visibility persisted to `dictationHistoryWindow` on the injected `AppState` (`.shared` by
/// default; tests inject a temp-directory-backed instance, mirroring
/// `MeetingWorkspaceWindowController`).
///
/// Built on the shared `FloatingPanel` base for the same reason `SessionListWindowController` is:
/// `FloatingPanel` overrides `canBecomeKey`/`canBecomeMain` to `true` so this window can accept
/// keyboard focus (e.g. a future search field in the list pane) despite `.nonactivatingPanel`
/// otherwise defaulting both to `false`.
///
/// This controller does not maintain its own static `shared` instance: per design doc section 6.1,
/// `WindowManager.showDictationHistory()` is the sole owner of the single cached instance (lazily
/// creating it once, then reusing it — the same pattern `WindowManager.showSettings()` uses for
/// `SettingsWindowController`).
///
/// Hosts `DictationHistoryView` (`docs/design/29-dictation-history.md` section 6.2/6.3:
/// `NavigationSplitView` list/detail, `DictationHistoryStore`-backed view model, `LLMUsageBadge`
/// footer), backed by its own fresh `DictationHistoryViewModel` -- the window controller itself
/// stays a thin AppKit/SwiftUI bridge, same division of labor as `SessionListWindowController`/
/// `SessionListView`.
@MainActor
final class DictationHistoryWindowController: NSWindowController, NSWindowDelegate {
    private let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "DictationHistoryWindowController")

    /// Injectable for testability, same pattern as `MeetingWorkspaceWindowController.appState`
    /// (`Kikimi/Window/MeetingWorkspaceWindowController.swift:88`) -- lets tests supply a
    /// temp-directory-backed `AppState` instead of mutating the developer's real
    /// `~/.local/state/kikimi/state.yaml`.
    private let appState: AppState

    /// Debounces `windowDidMove`/`windowDidResize` writes to `state.yaml`, matching
    /// `SessionListWindowController`'s own debounce (design doc section 6.1's "`SessionListWindowController`
    /// を…範として"). Not `static`/`let` (unlike the original single-instance value) so tests can shrink
    /// it well below the real 300ms to avoid slow/flaky sleeps.
    private var frameSaveWorkItem: DispatchWorkItem?
    var frameSaveDebounceInterval: TimeInterval = 0.3

    // Matches `DictationHistoryView`'s own `.frame(minWidth: 640, minHeight: 420)`
    // (`Kikimi/Views/DictationHistoryView.swift`) -- unlike `SessionListWindowController`, whose
    // `480x360` here is likewise kept identical to `SessionListView`'s own frame minimum, this must
    // stay in sync with `DictationHistoryView`'s minimum rather than reusing that unrelated value.
    private static let minimumSize = NSSize(width: 640, height: 420)

    init(appState: AppState = .shared) {
        self.appState = appState
        let savedState = appState.data.dictationHistoryWindow
        // `FloatingWindowState.default` (500x400, `Kikimi/Config/AppState.swift`) is shared with
        // `sessionListWindow`, sized for `SessionListWindowController`'s own smaller `480x360`
        // minimum -- below this window's `640x420` minimum above. Clamp so a first-launch (or
        // otherwise never-resized-larger) window never opens smaller than what
        // `DictationHistoryView` itself declares as its minimum.
        let frame = NSRect(
            x: CGFloat(savedState.x),
            y: CGFloat(savedState.y),
            width: max(CGFloat(savedState.width), Self.minimumSize.width),
            height: max(CGFloat(savedState.height), Self.minimumSize.height)
        )

        let panel = FloatingPanel(contentRect: frame)
        panel.title = "ディクテーション履歴"
        panel.titleVisibility = .visible
        panel.isMovableByWindowBackground = true
        panel.isRestorable = false
        panel.minSize = Self.minimumSize

        super.init(window: panel)
        panel.delegate = self

        let hostingView = FirstMouseHostingView(rootView: DictationHistoryView(viewModel: DictationHistoryViewModel()))
        panel.contentView = hostingView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Shows the window. `WindowManager.showDictationHistory()` calls this on its cached singleton
    /// instance (design doc section 6.1); repeated calls simply re-front the same window.
    func show() {
        logger.debug("Showing Dictation History window")
        // `KIKIMI_TEST_HIDDEN=1` (`HiddenTestMode`, `Kikimi/Window/FloatingPanel.swift`): see
        // `SessionListWindowController.show()` for the full rationale -- kept identical here so
        // this window never makes Kikimi the frontmost app during automated verification either.
        if !HiddenTestMode.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
        window?.makeKeyAndOrderFront(nil)
        persistVisibility(true)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        logger.debug("Dictation History window closing")
        // Flush any pending debounced frame save immediately so closing the window right after a
        // drag/resize doesn't lose the final position (matches `SessionListWindowController`).
        frameSaveWorkItem?.cancel()
        frameSaveWorkItem = nil
        saveFrame()
        persistVisibility(false)
    }

    func windowDidMove(_ notification: Notification) {
        scheduleFrameSave()
    }

    func windowDidResize(_ notification: Notification) {
        scheduleFrameSave()
    }

    // MARK: - `state.yaml` persistence (`docs/design/29-dictation-history.md` section 6.1)

    private func scheduleFrameSave() {
        frameSaveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.saveFrame() }
        frameSaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + frameSaveDebounceInterval, execute: workItem)
    }

    private func saveFrame() {
        guard let frame = window?.frame else { return }
        appState.updateDictationHistoryWindow { state in
            state.x = Double(frame.origin.x)
            state.y = Double(frame.origin.y)
            state.width = Double(frame.size.width)
            state.height = Double(frame.size.height)
        }
    }

    private func persistVisibility(_ visible: Bool) {
        appState.updateDictationHistoryWindow { state in
            state.visible = visible
        }
    }
}
