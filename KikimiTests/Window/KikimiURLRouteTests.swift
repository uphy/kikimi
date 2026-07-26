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

    @Test("kikimi://window/new with no query parses to .newWindow(basedOn: nil)")
    func newWindowWithoutBasedOn() {
        #expect(KikimiURLRoute.parse(url("kikimi://window/new")) == .newWindow(basedOn: nil))
    }

    @Test("kikimi://window/new?based_on=<id> parses to .newWindow(basedOn: <id>)")
    func newWindowWithBasedOn() {
        let route = KikimiURLRoute.parse(url("kikimi://window/new?based_on=2026-07-01T14-30-00_a1b2c3d4"))
        #expect(route == .newWindow(basedOn: "2026-07-01T14-30-00_a1b2c3d4"))
    }

    @Test("kikimi://window/new?based_on= (empty value) normalizes to .newWindow(basedOn: nil)")
    func newWindowWithEmptyBasedOnNormalizesToNil() {
        #expect(KikimiURLRoute.parse(url("kikimi://window/new?based_on=")) == .newWindow(basedOn: nil))
    }

    @Test("unrelated query parameters are ignored")
    func newWindowIgnoresUnrelatedQueryParameters() {
        let route = KikimiURLRoute.parse(url("kikimi://window/new?foo=bar&based_on=abc"))
        #expect(route == .newWindow(basedOn: "abc"))
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
}
