import AppKit
import SwiftUI

// MARK: - GlossaryQuickAddWindowController

/// Owns the single メニューバー "用語を登録…" quick-add window (`WindowManager.showGlossaryQuickAdd()`).
/// Built on the shared `FloatingPanel` base like every other Kikimi window kind (Session Window /
/// Session List / Settings / Dictation History); modeled most closely on `SettingsWindowController`
/// (`Kikimi/Window/SettingsWindowController.swift`) -- a single long-lived instance, re-centered
/// rather than frame-persisted (this is a transient one-off form, not something worth a `state.yaml`
/// entry).
///
/// Unlike `SettingsWindowController`, `show()` rebuilds `GlossaryQuickAddView` from scratch on every
/// call instead of reusing one fixed instance: the view saves-and-closes on success (there is no
/// "stay open" mode, see that type's doc comment), so by the time this window is shown again its
/// previous content view would otherwise still be holding stale/blank `@State`. Rebuilding also
/// re-triggers `.onAppear`, which is what puts focus back in the term field every time the window is
/// (re-)shown, including when it was merely fronted rather than freshly created.
@MainActor
final class GlossaryQuickAddWindowController: NSWindowController {
    private static let defaultSize = CGSize(width: 380, height: 240)

    init() {
        let panel = FloatingPanel(contentRect: CGRect(origin: .zero, size: Self.defaultSize))
        panel.title = "用語を登録"
        panel.isMovableByWindowBackground = true
        // Matches `SettingsWindowController`: a small, one-off form has nothing worth persisting to
        // `state.yaml`, so there is no saved frame for AppKit's own autosave to restore either.
        panel.isRestorable = false

        super.init(window: panel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Shows the window, re-centering it every time and installing a fresh `GlossaryQuickAddView`
    /// (see type doc comment for why the content view -- not just the window -- is rebuilt on every
    /// call).
    func show() {
        let view = GlossaryQuickAddView(onDismiss: { [weak self] in self?.window?.close() })
        (window as? FloatingPanel)?.contentView = FirstMouseHostingView(rootView: view)

        window?.center()
        // `KIKIMI_TEST_HIDDEN=1`: see `SettingsWindowController.show()`'s matching comment -- skip
        // explicit app activation so the alpha-0 panel never flips Kikimi to frontmost during
        // automated verification.
        if !HiddenTestMode.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
        window?.makeKeyAndOrderFront(nil)
    }
}
