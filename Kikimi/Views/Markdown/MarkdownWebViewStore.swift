import Foundation

// MARK: - MarkdownWebViewStore

/// Owns one `MarkdownWebViewHost` per Markdown surface in a Session Window
/// (`docs/design/39-webview-markdown.md` MD2).
///
/// Held by `MeetingWorkspaceWindowController`, i.e. for the window's whole lifetime. This is the
/// whole point of the type: Phase A0 measured that switching tabs tears the `NSViewRepresentable`
/// down, so a web view created inside `makeNSView` would re-parse the 312KB bundle — and lose its
/// scroll position — every time the user came back to the tab.
@MainActor
final class MarkdownWebViewStore {
    enum Slot: String, CaseIterable {
        /// Summary tab, meeting-state pane. Holds the whole summary when the template could not be
        /// split (`docs/design/47-summary-split-pane.md` §4.1).
        case summary
        /// Summary tab, 議事詳細 pane. Only ever created once a split actually succeeds -- see
        /// `SummaryTabView.topicsMarkdownHost`, which is a closure precisely so that a session with an
        /// unsplittable template never pays for a second web view.
        case summaryTopics
        case watchers
        case chat
    }

    private var hosts: [Slot: MarkdownWebViewHost] = [:]

    /// The host for `slot`, created (and started loading) on first use. A window whose user never
    /// opens the Watchers tab never pays for its web view.
    func host(for slot: Slot) -> MarkdownWebViewHost {
        if let existing = hosts[slot] { return existing }
        let host = MarkdownWebViewHost()
        host.start()
        hosts[slot] = host
        return host
    }

    /// The host for `slot` **only if it already exists**. Used by the verification bridge
    /// (`docs/design/39-webview-markdown.md` MD12), which must not bring a web view into being as a
    /// side effect of being asked about it.
    func existingHost(for slot: Slot) -> MarkdownWebViewHost? {
        hosts[slot]
    }

    /// Called when the window closes. Web views are otherwise kept alive on purpose, so nothing
    /// else should drop them.
    func tearDown() {
        hosts.removeAll()
    }
}
