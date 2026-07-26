import AppKit
import SwiftUI

/// Manages the Settings window (`docs/design/06-ui-panels.md` 8章, Phase 1 minimal scope).
///
/// Built on the shared `FloatingPanel` base used by all three of Kikimi's window kinds
/// (Session Window / Session List / Settings; see `FloatingPanel`'s doc comment and
/// `docs/design/06-ui-panels.md` 2-3章).
///
/// Unlike Session Window windows, the Settings window's frame is **not** persisted to
/// `AppState`/`state.yaml`: kikimi.md 12章's `state.yaml` sample has no `settings_window` key,
/// and 06-ui-panels.md 8章 treats this as a deliberate, conservative choice not to add an
/// undocumented item. Every `show()` call re-centers the window instead of restoring a saved
/// frame.
///
/// `WindowManager.shared.showSettings()` (06-ui-panels.md 5.2章, not yet implemented) is expected
/// to own a single long-lived instance of this controller and call `show()` on it; that wiring is
/// out of scope for this module.
@MainActor
final class SettingsWindowController: NSWindowController {
    private static let defaultSize = CGSize(width: 480, height: 360)

    private let viewModel = SettingsViewModel()

    init() {
        let panel = FloatingPanel(contentRect: CGRect(origin: .zero, size: Self.defaultSize))
        panel.title = "設定"
        panel.isMovableByWindowBackground = true
        // The frame is intentionally never restored from AppState (see type doc comment above),
        // so there is nothing meaningful for AppKit's own window-frame-autosave to persist either.
        panel.isRestorable = false

        super.init(window: panel)

        panel.contentView = FirstMouseHostingView(rootView: SettingsView(viewModel: viewModel))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Shows the window, re-centering it on screen every time (frame is intentionally not
    /// persisted; see type doc comment above).
    func show() {
        window?.center()
        // `KIKIMI_TEST_HIDDEN=1`: see `SessionListWindowController.show()`'s matching comment --
        // skip explicit app activation so the alpha-0 panel never flips Kikimi to frontmost during
        // automated verification.
        if !HiddenTestMode.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
        window?.makeKeyAndOrderFront(nil)
        // `SettingsWindowController` (and its `viewModel`) is a long-lived singleton
        // (`WindowManager.showSettings()`), so the 話者 tab's speakers/map/close-pairs would
        // otherwise only ever reflect whatever `VoiceprintStore` held the first time the tab
        // appeared -- stale for the rest of the app's lifetime, notably during an in-progress
        // meeting where voiceprints keep changing. Re-fetch on every `show()` instead, matching
        // `SessionListWindowController.show()`'s same `Task { await viewModel.refresh() }` pattern.
        Task { await viewModel.refreshVoiceprintSpeakers() }
    }
}
