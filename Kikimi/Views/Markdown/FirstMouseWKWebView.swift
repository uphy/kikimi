import AppKit
import WebKit

// MARK: - FirstMouseWKWebView

/// The `WKWebView` subclass every Kikimi Markdown view uses (`docs/design/39-webview-markdown.md`
/// MD5/MD6).
///
/// Two overrides, both required by the fact that every Kikimi window is a `.nonactivatingPanel`
/// (`FloatingPanel`, kikimi.md 10 章):
///
/// - `acceptsFirstMouse` — the click that makes a non-key panel key must also register as a normal
///   click inside the page. `FirstMouseHostingView` (`Kikimi/Window/FloatingPanel.swift`) already
///   does this for SwiftUI content, but `acceptsFirstMouse(for:)` is asked of the view the click
///   *hit-tests to*, and clicks landing inside a web view hit-test into `WKWebView`'s own subviews.
///   Without this override, the first click on a link or button in a non-key panel is swallowed.
///   Chirami makes the same tradeoff in its editor web view (`chirami-map.md` 3 章).
/// - `willOpenMenu` — WebKit's default context menu offers "Reload". A reload re-runs
///   `index.html` from scratch while Swift keeps thinking the page still holds the content it last
///   pushed, leaving the view blank until the next `setContent` (design 39 §7). Nothing in the
///   default menu is useful for a read-only render, except copy/select-all, so the menu is stripped
///   down to those.
final class FirstMouseWKWebView: WKWebView {
    /// Invoked whenever the panel switches between light and dark, so the host can re-resolve the
    /// `NSColor`s it pushes into the page as CSS variables (design 39 MD13). An override beats KVO
    /// on `effectiveAppearance` here: AppKit calls it at exactly the point where
    /// `NSAppearance.current` is already the new one, which is what `NSColor` resolution needs.
    var onAppearanceChange: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        // Identifiers are stable across macOS versions; anything not explicitly kept is removed so
        // a future WebKit addition does not silently reappear in the menu.
        let allowed: Set<NSUserInterfaceItemIdentifier> = [
            .init("WKMenuItemIdentifierCopy"),
            .init("WKMenuItemIdentifierCopyLinkText")
        ]
        for item in menu.items where !allowed.contains(item.identifier ?? .init("")) {
            menu.removeItem(item)
        }
    }
}
