import Foundation
import Testing

@testable import Kikimi

/// Layer 1 (unit) coverage for `KikimiURLRoute.parse(_:)`
/// (`Kikimi/Window/KikimiURLRoute.swift`, `docs/design/09-raycast-integration.md` sections 3/7).
/// A pure function with no `WindowManager`/`SessionStore` dependency, so every case is exercised
/// directly here rather than deferred to the `kikimi-verify` skill (section 7).
@Suite("KikimiURLRoute")
struct KikimiURLRouteTests {
    private func url(_ string: String) -> URL {
        guard let url = URL(string: string) else {
            Issue.record("Failed to construct URL from \(string)")
            return URL(fileURLWithPath: "/dev/null")
        }
        return url
    }

    // MARK: window/new

    @Test("kikimi://window/new with no query parses to .newWindow(seed: .none)")
    func newWindowWithoutBasedOn() {
        #expect(KikimiURLRoute.parse(url("kikimi://window/new")) == .newWindow(seed: .none))
    }

    @Test("kikimi://window/new?based_on=<id> parses to .newWindow(seed: .basedOn(sessionId:))")
    func newWindowWithBasedOn() {
        let route = KikimiURLRoute.parse(url("kikimi://window/new?based_on=2026-07-01T14-30-00_a1b2c3d4"))
        #expect(route == .newWindow(seed: .basedOn(sessionId: "2026-07-01T14-30-00_a1b2c3d4")))
    }

    @Test("kikimi://window/new?based_on= (empty value) normalizes to .newWindow(seed: .none)")
    func newWindowWithEmptyBasedOnNormalizesToNil() {
        #expect(KikimiURLRoute.parse(url("kikimi://window/new?based_on=")) == .newWindow(seed: .none))
    }

    @Test("unrelated query parameters are ignored")
    func newWindowIgnoresUnrelatedQueryParameters() {
        let route = KikimiURLRoute.parse(url("kikimi://window/new?foo=bar&based_on=abc"))
        #expect(route == .newWindow(seed: .basedOn(sessionId: "abc")))
    }

    // MARK: window/new?profile= (docs/design/41-meeting-profiles.md §7)

    @Test("kikimi://window/new?profile=<id> parses to .newWindow(seed: .profile(id:))")
    func newWindowWithProfile() {
        let route = KikimiURLRoute.parse(url("kikimi://window/new?profile=daily-scrum"))
        #expect(route == .newWindow(seed: .profile(id: "daily-scrum")))
    }

    @Test("kikimi://window/new?profile= (empty value) normalizes to .newWindow(seed: .none)")
    func newWindowWithEmptyProfileNormalizesToNone() {
        #expect(KikimiURLRoute.parse(url("kikimi://window/new?profile=")) == .newWindow(seed: .none))
    }

    @Test("both based_on and profile specified is malformed and returns nil (whichever wins would misrepresent intent)")
    func newWindowWithBothBasedOnAndProfileReturnsNil() {
        let route = KikimiURLRoute.parse(
            url("kikimi://window/new?based_on=2026-07-01T14-30-00_a1b2c3d4&profile=daily-scrum")
        )
        #expect(route == nil)
    }

    @Test("both based_on and profile specified but one is an empty value still normalizes before the exclusivity check, so it resolves to the non-empty one")
    func newWindowWithOneEmptyAndOneNonEmptyResolvesToTheNonEmptyOne() {
        let basedOnEmpty = KikimiURLRoute.parse(url("kikimi://window/new?based_on=&profile=daily-scrum"))
        #expect(basedOnEmpty == .newWindow(seed: .profile(id: "daily-scrum")))

        let profileEmpty = KikimiURLRoute.parse(url("kikimi://window/new?based_on=abc&profile="))
        #expect(profileEmpty == .newWindow(seed: .basedOn(sessionId: "abc")))
    }

    @Test("both based_on and profile given as empty values normalizes to .newWindow(seed: .none)")
    func newWindowWithBothEmptyNormalizesToNone() {
        #expect(KikimiURLRoute.parse(url("kikimi://window/new?based_on=&profile=")) == .newWindow(seed: .none))
    }

    // MARK: record/quick

    @Test("kikimi://record/quick parses to .recordQuick")
    func recordQuick() {
        #expect(KikimiURLRoute.parse(url("kikimi://record/quick")) == .recordQuick)
    }

    // MARK: Rejections

    @Test("wrong scheme returns nil")
    func wrongSchemeReturnsNil() {
        #expect(KikimiURLRoute.parse(url("https://window/new")) == nil)
    }

    @Test("scheme comparison is case-insensitive")
    func schemeIsCaseInsensitive() {
        #expect(KikimiURLRoute.parse(url("KIKIMI://record/quick")) == .recordQuick)
    }

    @Test("unknown host returns nil")
    func unknownHostReturnsNil() {
        #expect(KikimiURLRoute.parse(url("kikimi://unknown/new")) == nil)
    }

    @Test("unknown path under a known host returns nil")
    func unknownPathReturnsNil() {
        #expect(KikimiURLRoute.parse(url("kikimi://window/other")) == nil)
    }

    @Test("missing path returns nil")
    func missingPathReturnsNil() {
        #expect(KikimiURLRoute.parse(url("kikimi://window")) == nil)
    }

    @Test("record host with wrong path returns nil")
    func recordHostWithWrongPathReturnsNil() {
        #expect(KikimiURLRoute.parse(url("kikimi://record/slow")) == nil)
    }

    // MARK: - kikimi://debug/webview (design 39 MD12)

    @Test("a dump request parses its target and output path")
    func debugWebViewDump() {
        let route = KikimiURLRoute.parse(URL(string: "kikimi://debug/webview?target=summary&action=dump&out=/tmp/x.txt")!)
        #expect(route == .debugWebView(target: .summary, action: .dump(out: "/tmp/x.txt")))
    }

    @Test("action defaults to dump, and an empty out is normalized to nil (log instead of a file)")
    func debugWebViewDumpDefaults() {
        #expect(KikimiURLRoute.parse(URL(string: "kikimi://debug/webview?target=chat")!)
            == .debugWebView(target: .chat, action: .dump(out: nil)))
        #expect(KikimiURLRoute.parse(URL(string: "kikimi://debug/webview?target=chat&out=")!)
            == .debugWebView(target: .chat, action: .dump(out: nil)))
    }

    @Test("a click request carries the data-testid to press")
    func debugWebViewClick() {
        let route = KikimiURLRoute.parse(URL(string: "kikimi://debug/webview?target=chat&action=click&testid=chat-copy-a1")!)
        #expect(route == .debugWebView(target: .chat, action: .click(testId: "chat-copy-a1", out: nil)))

        // `out` lets a script read the outcome instead of scraping the log.
        let withOut = KikimiURLRoute.parse(
            URL(string: "kikimi://debug/webview?target=chat&action=click&testid=chat-copy-a1&out=/tmp/r.txt")!
        )
        #expect(withOut == .debugWebView(target: .chat, action: .click(testId: "chat-copy-a1", out: "/tmp/r.txt")))
    }

    @Test("every surface is addressable, including the zoom overlay (design 40)")
    func debugWebViewTargets() {
        for target in ["summary", "watchers", "chat", "diagram"] {
            let route = KikimiURLRoute.parse(URL(string: "kikimi://debug/webview?target=\(target)")!)
            #expect(route != nil, "target \(target) should parse")
        }
    }

    @Test("a malformed debug URL is rejected rather than guessed at")
    func debugWebViewRejections() {
        // A mistyped target must fail loudly: silently checking the wrong surface is worse than
        // failing.
        #expect(KikimiURLRoute.parse(URL(string: "kikimi://debug/webview?target=nope")!) == nil)
        #expect(KikimiURLRoute.parse(URL(string: "kikimi://debug/webview")!) == nil)
        #expect(KikimiURLRoute.parse(URL(string: "kikimi://debug/webview?target=chat&action=shout")!) == nil)
        // click with no id has nothing to press.
        #expect(KikimiURLRoute.parse(URL(string: "kikimi://debug/webview?target=chat&action=click")!) == nil)
        #expect(KikimiURLRoute.parse(URL(string: "kikimi://debug/webview?target=chat&action=click&testid=")!) == nil)
        #expect(KikimiURLRoute.parse(URL(string: "kikimi://debug/other?target=chat")!) == nil)
    }
}
