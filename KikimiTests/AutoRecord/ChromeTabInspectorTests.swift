import Foundation
import Testing

@testable import Kikimi

/// Pure parsing / mapping tests for `ChromeTabInspector` (`docs/design/50-meet-auto-record.md` section 2.2).
/// The AppleScript call itself is verified by hand.
@Suite("ChromeTabInspector parsing")
struct ChromeTabInspectorTests {
    @Test("meeting code is taken from the URL, ignoring query strings")
    func meetCode() {
        #expect(ChromeTabInspector.meetCode(fromURL: "https://meet.google.com/abc-defg-hij") == "abc-defg-hij")
        #expect(ChromeTabInspector.meetCode(fromURL: "https://meet.google.com/abc-defg-hij?authuser=1") == "abc-defg-hij")
        #expect(ChromeTabInspector.meetCode(fromURL: "https://meet.google.com/abc-defg-hij?authuser=x&pli=1") == "abc-defg-hij")
        #expect(ChromeTabInspector.meetCode(fromURL: "https://meet.google.com/meet/abc-defg-hij?authuser=a@example.com") == "abc-defg-hij")
        #expect(ChromeTabInspector.meetCode(fromURL: "https://meet.google.com/_meet/abc-defg-hij") == "abc-defg-hij")
        #expect(ChromeTabInspector.meetCode(fromURL: "https://meet.google.com/abc-defg-hijk") == nil)
    }

    @Test("non-meeting Meet URLs and other hosts are rejected")
    func notMeetCode() {
        #expect(ChromeTabInspector.meetCode(fromURL: "https://meet.google.com/") == nil)
        #expect(ChromeTabInspector.meetCode(fromURL: "https://meet.google.com/landing") == nil)
        #expect(ChromeTabInspector.meetCode(fromURL: "https://meet.google.com/new") == nil)
        #expect(ChromeTabInspector.meetCode(fromURL: "https://example.com/abc-defg-hij") == nil)
        #expect(ChromeTabInspector.meetCode(fromURL: "https://www.google.com/?q=meet.google.com/abc-defg-hij") == nil)
        #expect(ChromeTabInspector.meetCode(fromURL: "") == nil)
    }

    @Test("title cleaning removes the PiP marker and Meet prefix")
    func cleanTitle() {
        #expect(ChromeTabInspector.cleanTitle("Meet - Weekly sync") == "Weekly sync")
        #expect(ChromeTabInspector.cleanTitle("↗ Meet - Weekly sync") == "Weekly sync")
        #expect(ChromeTabInspector.cleanTitle("↗ Weekly sync") == "Weekly sync")
        #expect(ChromeTabInspector.cleanTitle("  Weekly sync \n") == "Weekly sync")
        #expect(ChromeTabInspector.cleanTitle("abc-defg-hij") == "abc-defg-hij")
    }

    @Test("script output is parsed into tabs")
    func parseTabs() {
        let f = ChromeTabInspector.fieldSeparator
        let r = ChromeTabInspector.recordSeparator
        let output = "1\(f)https://meet.google.com/abc-defg-hij?authuser=0\(f)↗ Meet - 定例\(r)"
            + "0\(f)https://meet.google.com/landing\(f)Meet\(r)"
            + "0\(f)https://meet.google.com/xyz-wvut-srq\(f)Other\(r)"
            + "2\(f)https://meet.google.com/fff-ffff-fff\(f)Front\(r)"
        let tabs = ChromeTabInspector.parseTabs(output)
        #expect(tabs == [
            MeetTab(code: "abc-defg-hij", title: "定例", isActive: true),
            MeetTab(code: "xyz-wvut-srq", title: "Other", isActive: false),
            MeetTab(code: "fff-ffff-fff", title: "Front", isActive: true, isFrontmost: true)
        ])
    }

    @Test("window records are skipped by the tab parser and summarized without paths")
    func windowRecords() {
        let f = ChromeTabInspector.fieldSeparator
        let r = ChromeTabInspector.recordSeparator
        let output = "#\(f)1\(f)1\(f)about:blank\(r)"
            + "#\(f)2\(f)30\(f)https://meet.google.com/abc-defg-hij?authuser=0\(r)"
            + "2\(f)https://meet.google.com/abc-defg-hij?authuser=0\(f)定例\(r)"
        #expect(ChromeTabInspector.parseTabs(output) == [
            MeetTab(code: "abc-defg-hij", title: "定例", isActive: true, isFrontmost: true)
        ])
        #expect(ChromeTabInspector.windowSummary(output) == "w1 tabs=1 active=about:blank, w2 tabs=30 active=https://meet.google.com")
    }

    @Test("empty script output yields no tabs")
    func parseEmpty() {
        #expect(ChromeTabInspector.parseTabs("").isEmpty)
    }

    @Test("Apple event error codes map to failures")
    func errorCodes() {
        #expect(ChromeTabInspector.failure(forErrorCode: -1743) == .notAuthorized)
        #expect(ChromeTabInspector.failure(forErrorCode: -1744) == .notDetermined)
        #expect(ChromeTabInspector.failure(forErrorCode: -1712) == .timeout)
        #expect(ChromeTabInspector.failure(forErrorCode: -1728) == nil)
    }

    @Test("Chrome helper bundle ids match by prefix")
    func chromeBundlePrefix() {
        #expect(ChromeAudioActivityMonitor.isChromeBundleId("com.google.Chrome"))
        #expect(ChromeAudioActivityMonitor.isChromeBundleId("com.google.Chrome.helper"))
        #expect(!ChromeAudioActivityMonitor.isChromeBundleId("com.apple.Safari"))
        #expect(!ChromeAudioActivityMonitor.isChromeBundleId(nil))
    }
}
