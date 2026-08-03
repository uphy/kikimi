import AppKit
import Testing

@testable import Kikimi

// MARK: - MarkdownWebViewContainer

/// Unit tests for `MarkdownWebViewContainer` (`Kikimi/Views/Markdown/MarkdownWebView.swift`), the
/// `NSView` that parks the store-owned `WKWebView` inside whichever SwiftUI subtree currently shows
/// it (`docs/design/39-webview-markdown.md` MD2).
///
/// The ordering these tests pin down is SwiftUI's, not ours: on a pane switch
/// (`MeetingTabView.content`'s `switch paneMode`) the *new* representable is made and updated before
/// the old one is dismantled, so `attach` on the incoming container runs before `detach` on the
/// outgoing one — with the same web view.
@Suite("MarkdownWebViewContainer")
@MainActor
struct MarkdownWebViewContainerTests {
    @Test("attach parents the web view")
    func attachParentsTheWebView() {
        let container = MarkdownWebViewContainer()
        let webView = NSView()

        container.attach(webView)

        #expect(webView.superview === container)
    }

    @Test("detach removes a web view this container still owns")
    func detachRemovesOwnWebView() {
        let container = MarkdownWebViewContainer()
        let webView = NSView()
        container.attach(webView)

        container.detach()

        #expect(webView.superview == nil)
    }

    @Test("the outgoing container's detach leaves the web view in the incoming container")
    func detachAfterHandoffKeepsWebViewInNewContainer() {
        let outgoing = MarkdownWebViewContainer()
        let incoming = MarkdownWebViewContainer()
        let webView = NSView()

        // "両方表示" -> "サマリのみ": SwiftUI attaches the new pane's container first...
        outgoing.attach(webView)
        incoming.attach(webView)
        // ...then dismantles the old one.
        outgoing.detach()

        #expect(webView.superview === incoming)
    }

    @Test("a container that lost the web view can take it back")
    func attachReclaimsWebViewAfterHandoff() {
        let first = MarkdownWebViewContainer()
        let second = MarkdownWebViewContainer()
        let webView = NSView()

        first.attach(webView)
        second.attach(webView)
        first.attach(webView)

        #expect(webView.superview === first)
    }

    @Test("attaching a different web view drops the previous one")
    func attachReplacesPreviousWebView() {
        let container = MarkdownWebViewContainer()
        let first = NSView()
        let second = NSView()

        container.attach(first)
        container.attach(second)

        #expect(first.superview == nil)
        #expect(second.superview === container)
    }
}
