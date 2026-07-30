import Foundation
import Testing

@testable import Kikimi

/// Layer 1 coverage for `MarkdownLinkRouter` (`docs/design/39-webview-markdown.md` §8.1). Pure --
/// no web view, no `NSWorkspace`.
@Suite("MarkdownLinkRouter")
struct MarkdownLinkRouterTests {
    @Test("a kikimi-seg: link yields the bare segment id")
    func segmentLink() {
        // The exact shape `WatcherViewRenderer.linkifySegmentIds` emits
        // (`Kikimi/Watchers/WatcherViewRenderer.swift:115`).
        #expect(MarkdownLinkRouter.route("kikimi-seg:seg_00042") == .segment("seg_00042"))
    }

    @Test("a kikimi-seg: link with no id is ignored rather than jumping to an empty segment")
    func segmentLinkWithoutID() {
        #expect(MarkdownLinkRouter.route("kikimi-seg:") == .ignored)
    }

    @Test("http and https links are handed to the system")
    func externalLinks() {
        #expect(MarkdownLinkRouter.route("https://example.com/a") == .external(URL(string: "https://example.com/a")!))
        #expect(MarkdownLinkRouter.route("http://example.com") == .external(URL(string: "http://example.com")!))
        // Scheme comparison is case-insensitive: an LLM writing `HTTPS://` should still open.
        #expect(MarkdownLinkRouter.route("HTTPS://example.com") == .external(URL(string: "HTTPS://example.com")!))
    }

    @Test("javascript: and other schemes are ignored (design 39 §5)")
    func dangerousSchemes() {
        #expect(MarkdownLinkRouter.route("javascript:alert(1)") == .ignored)
        #expect(MarkdownLinkRouter.route("file:///etc/passwd") == .ignored)
        #expect(MarkdownLinkRouter.route("kikimi://window/new") == .ignored)
    }

    @Test("empty and whitespace-only hrefs are ignored")
    func emptyLinks() {
        #expect(MarkdownLinkRouter.route("") == .ignored)
        #expect(MarkdownLinkRouter.route("   ") == .ignored)
    }

    @Test("surrounding whitespace does not change the destination")
    func trimming() {
        #expect(MarkdownLinkRouter.route("  kikimi-seg:seg_00007  ") == .segment("seg_00007"))
    }

    @Test("a relative path is ignored (nothing to navigate to; the page never navigates)")
    func relativePath() {
        #expect(MarkdownLinkRouter.route("./notes.md") == .ignored)
        #expect(MarkdownLinkRouter.route("#section") == .ignored)
    }
}
