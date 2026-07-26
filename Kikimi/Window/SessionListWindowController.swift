import AppKit
import OSLog
import SwiftUI

// MARK: - SessionListWindowController

/// Owns the single Session List window (kikimi.md 10 章 "Session List ウィンドウ"; `docs/design/
/// 06-ui-panels.md` section 7). A floating `.nonactivatingPanel` embedding `SessionListView` via
/// `NSHostingView`, close in spirit to Chirami's `DisplayPanel` (`chirami-map.md` 3 章): a single
/// long-lived panel that is shown/hidden rather than recreated per use.
///
/// Built on the shared `FloatingPanel` base (see its doc comment): a plain `NSPanel` with
/// `.nonactivatingPanel` in its style mask defaults `canBecomeKey`/`canBecomeMain` to `false`,
/// which would silently prevent the search `TextField` in `SessionListView` from ever accepting
/// keyboard input. `FloatingPanel` overrides both to `true` for exactly this reason.
///
/// This controller does not maintain its own static `shared` instance: per design doc section 7,
/// `WindowManager.showSessionList()` is the sole owner of the single cached instance (lazily
/// creating it once, then reusing it — the same "keyed dictionary, but with only one entry"
/// pattern Chirami's `WindowManager` uses for `NoteWindowController`s, `chirami-map.md` 3 章).
@MainActor
final class SessionListWindowController: NSWindowController, NSWindowDelegate {
    private let viewModel: SessionListViewModel
    private let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "SessionListWindowController")

    /// Debounces `windowDidMove`/`windowDidResize` writes to `state.yaml` (design doc section 9:
    /// "デバウンス（例: 300ms）してから保存し、ドラッグ中に大量の書き込みが発生しないようにする",
    /// mirroring Chirami's `NoteWindowController.saveWindowState()` throttling).
    private var frameSaveWorkItem: DispatchWorkItem?
    private static let frameSaveDebounceInterval: TimeInterval = 0.3

    private static let minimumSize = NSSize(width: 480, height: 360)

    // Note: no default value for `viewModel` here (unlike some other controllers) -- a default of
    // `SessionListViewModel()` would need to be evaluated in a synchronous, non-isolated context
    // (default parameter expressions run at the call site, not with this initializer's own
    // `@MainActor` isolation), which the compiler rejects since `SessionListViewModel.init()` is
    // itself `@MainActor`-isolated. Every call site already passes `viewModel` explicitly
    // (`WindowManager.showSessionList()`), so this isn't a behavior change.
    init(viewModel: SessionListViewModel) {
        self.viewModel = viewModel

        let savedState = AppState.shared.data.sessionListWindow
        let frame = NSRect(
            x: CGFloat(savedState.x),
            y: CGFloat(savedState.y),
            width: CGFloat(savedState.width),
            height: CGFloat(savedState.height)
        )

        let panel = FloatingPanel(contentRect: frame)
        panel.title = "Sessions"
        panel.titleVisibility = .visible
        panel.isMovableByWindowBackground = true
        panel.isRestorable = false
        panel.minSize = Self.minimumSize

        super.init(window: panel)
        panel.delegate = self

        let hostingView = FirstMouseHostingView(rootView: SessionListView(viewModel: viewModel))
        panel.contentView = hostingView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Shows the window and kicks off an async session-list reload. `WindowManager.showSessionList()`
    /// calls this on its cached singleton instance (design doc section 7); repeated calls simply
    /// re-front the same window and refresh its contents.
    func show() {
        logger.debug("Showing Session List window")
        // `KIKIMI_TEST_HIDDEN=1` (`HiddenTestMode`, `Kikimi/Window/FloatingPanel.swift`): skip the
        // explicit app activation so an auto-shown Session List (e.g. crash-recovery at launch,
        // `WindowManager.launch()`) never makes Kikimi the frontmost app during automated
        // verification -- the alpha-0 panel alone isn't enough to prevent that, since
        // `NSApp.activate` affects app activation independent of window visibility.
        if !HiddenTestMode.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
        window?.makeKeyAndOrderFront(nil)
        persistVisibility(true)
        Task { await viewModel.refresh() }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        logger.debug("Session List window closing")
        // Flush any pending debounced frame save immediately so closing the window right after a
        // drag/resize doesn't lose the final position (design doc section 9).
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

    // MARK: - `state.yaml` persistence (design doc section 5.1/9)

    private func scheduleFrameSave() {
        frameSaveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.saveFrame() }
        frameSaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.frameSaveDebounceInterval, execute: workItem)
    }

    private func saveFrame() {
        guard let frame = window?.frame else { return }
        AppState.shared.updateSessionListWindow { state in
            state.x = Double(frame.origin.x)
            state.y = Double(frame.origin.y)
            state.width = Double(frame.size.width)
            state.height = Double(frame.size.height)
        }
    }

    private func persistVisibility(_ visible: Bool) {
        AppState.shared.updateSessionListWindow { state in
            state.visible = visible
        }
    }
}
