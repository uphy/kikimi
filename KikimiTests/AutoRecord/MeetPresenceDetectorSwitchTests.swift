import Foundation
import Testing

@testable import Kikimi

/// `docs/design/50-meet-auto-record.md` section 2.3 "会議の切り替え": moving straight from one meeting to the
/// next keeps Chrome's audio up, so the switch is found by the periodic in-meeting tab check.
@Suite("MeetPresenceDetector meeting switch")
struct MeetPresenceDetectorSwitchTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let inOut = ChromeAudioActivity(input: true, output: true)

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private func tab(_ code: String, frontmost: Bool) -> MeetTab {
        MeetTab(code: code, title: code, isActive: true, isFrontmost: frontmost)
    }

    private func inMeeting(_ code: String = "aaa-aaaa-aaa") -> MeetPresenceDetector {
        var d = MeetPresenceDetector()
        let first = d.handleSnapshot(inOut, now: t0)
        _ = d.handleQueryResult(.tabs([tab(code, frontmost: true)]), generation: first.query!.generation, now: t0)
        return d
    }

    @Test("no switch check before the interval")
    func noCheckBeforeInterval() {
        var d = inMeeting()
        #expect(d.handleSnapshot(inOut, now: at(29)).query == nil)
        #expect(d.handleSnapshot(inOut, now: at(30)).query != nil)
    }

    @Test("a different meeting in the frontmost tab switches: left then joined")
    func switchesToFrontmostMeeting() {
        var d = inMeeting()
        let request = d.handleSnapshot(inOut, now: at(30)).query!
        let next = tab("bbb-bbbb-bbb", frontmost: true)
        let result = d.handleQueryResult(
            .tabs([tab("aaa-aaaa-aaa", frontmost: false), next]),
            generation: request.generation, now: at(31)
        )
        #expect(result.events == [.left(code: "aaa-aaaa-aaa"), .joined(next)])
        #expect(d.isInMeeting)
    }

    @Test("the same meeting in front, or another meeting in a background window, does not switch")
    func noSwitch() {
        var d = inMeeting()
        var request = d.handleSnapshot(inOut, now: at(30)).query!
        var result = d.handleQueryResult(.tabs([tab("aaa-aaaa-aaa", frontmost: true)]), generation: request.generation, now: at(31))
        #expect(result.events.isEmpty)

        request = d.handleSnapshot(inOut, now: at(61)).query!
        result = d.handleQueryResult(
            .tabs([tab("aaa-aaaa-aaa", frontmost: false), MeetTab(code: "bbb-bbbb-bbb", title: "", isActive: true)]),
            generation: request.generation, now: at(62)
        )
        #expect(result.events.isEmpty)
    }

    @Test("a failed switch check is retried after the interval")
    func failedCheckRetries() {
        var d = inMeeting()
        let request = d.handleSnapshot(inOut, now: at(30)).query!
        _ = d.handleQueryResult(.failed(.timeout), generation: request.generation, now: at(31))
        #expect(d.handleSnapshot(inOut, now: at(40)).query == nil)
        #expect(d.handleSnapshot(inOut, now: at(61)).query != nil)
    }

    @Test("only one switch check is in flight at a time")
    func oneCheckInFlight() {
        var d = inMeeting()
        #expect(d.handleSnapshot(inOut, now: at(30)).query != nil)
        #expect(d.handleSnapshot(inOut, now: at(31)).query == nil)
        #expect(d.handleSnapshot(inOut, now: at(90)).query == nil)
    }
}
