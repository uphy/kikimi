import AppKit
import SwiftUI

// MARK: - WindowDragBlocker

/// Stops a region of a `isMovableByWindowBackground` window from dragging the *window* when the mouse
/// goes down on it, so a SwiftUI drag gesture there can run instead.
///
/// Every Kikimi panel sets `isMovableByWindowBackground = true` (`SettingsWindowController`,
/// `SessionListWindowController`, ...). On mouse-down AppKit hit-tests the content view and, if the
/// view under the cursor reports `mouseDownCanMoveWindow == true`, begins a window drag and never
/// forwards the event to the gesture recognizers. Plain SwiftUI content (an `Image`, a `Text`) draws
/// into the hosting view's layer without any `NSView` of its own that could report `false` -- so the
/// 用語集 drag handle's `.draggable` never fired: the whole Settings window moved instead
/// (`docs/design/28-glossary.md` §4.3, 2026-07 の実機確認).
///
/// Inserting a real (invisible, zero-content) `NSView` behind the handle gives AppKit something to hit
/// that answers `false`. It handles no events itself, so mouse-down still reaches the hosting view's
/// gesture recognizers and the drag starts normally.
///
/// Use as `.background(WindowDragBlocker())` on the smallest region that needs it -- **not** on a whole
/// window, or the window becomes undraggable by its background.
struct WindowDragBlocker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { BlockingView() }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class BlockingView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
    }
}
