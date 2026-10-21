import Foundation
import Testing

@testable import Kikimi

@Suite("MeetPresenceDetector extra cases")
struct MeetPresenceDetectorExtraTests {
    private let t0 = Date(timeIntervalSince1970: 2_000_000)
    private let inOut = ChromeAudioActivity(input: true, output: true)
    private let outOnly = ChromeAudioActivity(input: false, output: true)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
    private let meet = MeetTab(code: "abc-defg-hij", title: "Weekly", isActive: true)

    @Test("ChromeAudioActivity.isActive is the OR of input and output")
    func isActive() {
        #expect(!ChromeAudioActivity.silent.isActive)
        #expect(ChromeAudioActivity(input: true, output: false).isActive)
        #expect(ChromeAudioActivity(input: false, output: true).isActive)
        #expect(inOut.isActive)
    }

    @Test("chromeNotRunning and timeout schedule a retry")
    func retriesOnNotRunningAndTimeout() {
        var d = MeetPresenceDetector()
        let q1 = d.handleSnapshot(inOut, now: t0).query!
        _ = d.handleQueryResult(.chromeNotRunning, generation: q1.generation, now: t0)
        #expect(!d.isChecking)
        #expect(d.handleSnapshot(inOut, now: at(5)).query != nil)
        let q2 = d.handleSnapshot(inOut, now: at(5)).query
        #expect(q2 == nil)  // already checking, no stacked query
        #expect(d.isChecking)
        _ = d.handleQueryResult(.failed(.timeout), generation: d.currentGeneration, now: at(5))
        #expect(!d.isChecking)
        #expect(d.handleSnapshot(inOut, now: at(15)).query != nil)
    }

    @Test("a result with a wrong generation is ignored")
    func wrongGeneration() {
        var d = MeetPresenceDetector()
        let q = d.handleSnapshot(inOut, now: t0).query!
        let out = d.handleQueryResult(.tabs([meet]), generation: q.generation + 1, now: t0)
        #expect(out.events.isEmpty)
        #expect(d.isChecking)
        #expect(!d.isInMeeting)
    }

    @Test("a result arriving when not checking is ignored")
    func resultWhileIdle() {
        var d = MeetPresenceDetector()
        let out = d.handleQueryResult(.tabs([meet]), generation: 0, now: t0)
        #expect(out.events.isEmpty)
        #expect(!d.isInMeeting)
    }

    @Test("retry wait returns to idle when audio goes quiet")
    func retryWaitQuiet() {
        var d = MeetPresenceDetector()
        let q = d.handleSnapshot(inOut, now: t0).query!
        _ = d.handleQueryResult(.tabs([]), generation: q.generation, now: t0)
        _ = d.handleSnapshot(.silent, now: at(1))
        // A fresh rise starts a new check immediately.
        #expect(d.handleSnapshot(inOut, now: at(2)).query != nil)
    }

    @Test("custom debounce and rejoin after leave work")
    func customDebounceAndRejoin() {
        var d = MeetPresenceDetector(retryDelays: [1], leaveDebounce: 1)
        let q = d.handleSnapshot(inOut, now: t0).query!
        _ = d.handleQueryResult(.tabs([meet]), generation: q.generation, now: t0)
        _ = d.handleSnapshot(outOnly, now: at(5))
        #expect(d.handleSnapshot(outOnly, now: at(6)).events == [.left(code: meet.code)])
        _ = d.handleSnapshot(.silent, now: at(7))
        let q2 = d.handleSnapshot(inOut, now: at(8)).query
        #expect(q2 != nil)
    }
}
