import AppKit
import OSLog

// MARK: - DiagramZoomPlacement

/// Which screen the overlay covers (`docs/design/40-diagram-zoom.md` DZ2).
///
/// Split out as a pure function so the one decision here is testable without an `NSWindow`: the
/// overlay follows the window whose diagram was clicked, and has to survive that window being gone
/// (closed between the click and the open).
enum DiagramZoomPlacement {
    /// `visibleFrame`, not `frame`: the overlay should not sit under the menu bar or the Dock.
    static func screenFrame(for anchor: NSWindow?, mainScreen: NSScreen? = NSScreen.main) -> NSRect {
        if let screen = anchor?.screen { return screen.visibleFrame }
        if let mainScreen { return mainScreen.visibleFrame }
        // No screens at all (headless / `KIKIMI_TEST_HIDDEN` on a detached session): any non-empty
        // rect keeps the panel constructible rather than crashing on a zero-sized frame.
        return NSRect(x: 0, y: 0, width: 1200, height: 800)
    }
}

// MARK: - DiagramZoomWindowController

/// The full-screen overlay that shows one mermaid diagram (`docs/design/40-diagram-zoom.md`).
///
/// Exists because the Session Window is deliberately narrow (kikimi.md 10 章) and a wide diagram
/// cannot be read in it — while widening the window would cover the meeting app the user is
/// watching. So the diagram gets a screen of its own, temporarily.
///
/// One instance for the whole app (`WindowManager`), and its web view is kept alive across
/// open/close cycles: `mermaid.bundle.js` is 3.3MB and reloading it on every zoom would be a visible
/// wait (DZ5).
@MainActor
final class DiagramZoomWindowController: NSWindowController {
    private static let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "MarkdownWebView")

    /// Not `private` so the verification bridge (design 39 MD12) can dump the overlay's page.
    let host = MarkdownWebViewHost()
    private let container = MarkdownWebViewContainer()
    /// Restored when the overlay closes, so dismissing it puts the reader back where they were.
    private weak var anchorWindow: NSWindow?

    init() {
        // Sized on every `show(...)`; this initial frame only has to be non-empty.
        let panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), style: .borderless)
        // DZ7: above the Session Window panels (`.floating`), which the overlay covers.
        panel.level = .modalPanel
        // The scrim is drawn by the page (design 40 §3.4), so the panel itself paints nothing.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isRestorable = false
        super.init(window: panel)

        panel.contentView = container
        host.onCloseDiagram = { [weak self] in self?.closeOverlay() }
        host.start()
        if let webView = host.webView {
            container.attach(webView)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Opens the overlay on `anchor`'s screen and draws `source`.
    func show(source: String, anchoredTo anchor: NSWindow?) {
        guard let window else { return }
        guard host.state != .failed(reason: "web assets missing") else {
            // Nothing useful to show: the body could not have drawn the diagram either, so the zoom
            // button should not have been there. Log rather than opening an empty screen.
            Self.logger.error("diagram zoom requested but web assets are missing")
            return
        }

        anchorWindow = anchor
        window.setFrame(DiagramZoomPlacement.screenFrame(for: anchor), display: false)
        host.setDiagram(source: source)
        // `makeKey`, not `makeKeyAndOrderFront(nil)` on the app: `.nonactivatingPanel` means Kikimi
        // still does not activate, but the panel needs key status to receive Escape and ⌘W (DZ6/DZ8,
        // both handled in the page since the web view holds focus).
        window.makeKeyAndOrderFront(nil)
    }

    /// Hides the overlay and hands key status back to whatever the reader came from.
    func closeOverlay() {
        window?.orderOut(nil)
        anchorWindow?.makeKeyAndOrderFront(nil)
        anchorWindow = nil
    }
}
