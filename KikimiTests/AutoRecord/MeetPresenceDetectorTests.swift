import Foundation
import Testing

@testable import Kikimi

/// Pure-state-machine tests for `docs/design/50-meet-auto-record.md` section 2.3 (time is injected).
@Suite("MeetPresenceDetector")
struct MeetPresenceDetectorTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let silent = ChromeAudioActivity.silent
    private let inOut = ChromeAudioActivity(input: true, output: true)
    private let outOnly = ChromeAudioActivity(input: false, output: true)

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private func tab(_ code: String = "abc-defg-hij", active: Bool = true) -> MeetTab {
        MeetTab(code: code, title: "Weekly", isActive: active)
    }

    /// Detector already in a meeting at t0 (input + output up, tab found).
    private func joinedDetector(tab meetTab: MeetTab? = nil, audio: ChromeAudioActivity? = nil) -> MeetPresenceDetector {
        var d = MeetPresenceDetector()
        let first = d.handleSnapshot(audio ?? inOut, now: t0)
        _ = d.handleQueryResult(.tabs([meetTab ?? tab()]), generation: first.query!.generation, now: t0)
        return d
    }

    @Test("output rise with a Meet tab joins")
    func outputRiseJoins() {
        var d = MeetPresenceDetector()
        let first = d.handleSnapshot(outOnly, now: t0)
        #expect(first.query != nil)
        let result = d.handleQueryResult(.tabs([tab()]), generation: first.query!.generation, now: at(1))
        #expect(result.events == [.joined(tab())])
    }

    @Test("input rising while output already on queries again")
    func inputRiseWhileYouTube() {
        var d = MeetPresenceDetector()
        let first = d.handleSnapshot(outOnly, now: t0)
        _ = d.handleQueryResult(.tabs([]), generation: first.query!.generation, now: at(1))
        // Meet joined while the YouTube output keeps playing: input rises.
        _ = d.handleSnapshot(outOnly, now: at(2))
        let rise = d.handleSnapshot(inOut, now: at(10))
        // Still in retry schedule from the first rise: 5s retry is due, so a query is requested.
        #expect(rise.query != nil)
    }

    @Test("lobby screen counts as joined")
    func lobbyIsJoined() {
        var d = MeetPresenceDetector()
        let first = d.handleSnapshot(inOut, now: t0)
        let result = d.handleQueryResult(.tabs([MeetTab(code: "abc-defg-hij", title: "予定名", isActive: true)]), generation: first.query!.generation, now: at(1))
        #expect(result.events.count == 1)
    }

    @Test("no Meet tab retries at 5, 15 and 30 seconds, then stops")
    func retrySchedule() {
        var d = MeetPresenceDetector()
        var request = d.handleSnapshot(outOnly, now: t0).query!
        #expect(d.handleQueryResult(.tabs([]), generation: request.generation, now: at(1)).events.isEmpty)

        for (due, failing) in [(5.0, ChromeTabInspectionResult.tabs([])), (15.0, .failed(.timeout)), (30.0, .chromeNotRunning)] {
            // Not yet due.
            #expect(d.handleSnapshot(outOnly, now: at(due - 1)).query == nil)
            let output = d.handleSnapshot(outOnly, now: at(due))
            #expect(output.query != nil)
            request = output.query!
            _ = d.handleQueryResult(failing, generation: request.generation, now: at(due + 0.5))
        }
        // Exhausted: nothing more while audio stays on.
        #expect(d.handleSnapshot(outOnly, now: at(60)).query == nil)
        #expect(d.handleSnapshot(outOnly, now: at(600)).query == nil)

        // Joining Meet while the output keeps playing: input rises and a fresh query starts.
        let rise = d.handleSnapshot(inOut, now: at(601))
        #expect(rise.query != nil)
        let result = d.handleQueryResult(.tabs([tab()]), generation: rise.query!.generation, now: at(602))
        #expect(result.events == [.joined(tab())])
    }

    @Test("retry that finds a Meet tab joins")
    func retryJoins() {
        var d = MeetPresenceDetector()
        let first = d.handleSnapshot(outOnly, now: t0).query!
        _ = d.handleQueryResult(.failed(.other(-1728)), generation: first.generation, now: at(1))
        let retry = d.handleSnapshot(outOnly, now: at(5)).query!
        let result = d.handleQueryResult(.tabs([tab()]), generation: retry.generation, now: at(6))
        #expect(result.events == [.joined(tab())])
    }

    @Test("notAuthorized goes to exhausted and re-queries once after permission is granted")
    func permissionRequery() {
        var d = MeetPresenceDetector()
        let first = d.handleSnapshot(inOut, now: t0).query!
        _ = d.handleQueryResult(.failed(.notAuthorized), generation: first.generation, now: at(1))
        // No retries even when the schedule would be due.
        #expect(d.handleSnapshot(inOut, automationPermitted: false, now: at(6)).query == nil)
        let requery = d.handleSnapshot(inOut, automationPermitted: true, now: at(7))
        #expect(requery.query != nil)
        _ = d.handleQueryResult(.failed(.notAuthorized), generation: requery.query!.generation, now: at(8))
        // Only once per audio session.
        #expect(d.handleSnapshot(inOut, automationPermitted: true, now: at(9)).query == nil)
    }

    @Test("notDetermined also skips retries")
    func notDeterminedExhausts() {
        var d = MeetPresenceDetector()
        let first = d.handleSnapshot(inOut, now: t0).query!
        _ = d.handleQueryResult(.failed(.notDetermined), generation: first.generation, now: at(1))
        #expect(d.handleSnapshot(inOut, now: at(5)).query == nil)
        #expect(d.handleSnapshot(inOut, now: at(15)).query == nil)
    }

    @Test("audio dropping during a query returns to idle and discards the late result")
    func staleResultDiscarded() {
        var d = MeetPresenceDetector()
        let first = d.handleSnapshot(inOut, now: t0).query!
        _ = d.handleSnapshot(silent, now: at(1))
        let late = d.handleQueryResult(.tabs([tab()]), generation: first.generation, now: at(2))
        #expect(late.events.isEmpty)
        #expect(!d.isInMeeting)
        // A fresh rise starts a new query with a newer generation.
        let again = d.handleSnapshot(inOut, now: at(3)).query
        #expect(again != nil)
        #expect(again!.generation > first.generation)
    }

    @Test("output alone remaining keeps checking")
    func partialDropKeepsChecking() {
        var d = MeetPresenceDetector()
        let first = d.handleSnapshot(inOut, now: t0).query!
        _ = d.handleSnapshot(outOnly, now: at(1))
        #expect(d.isChecking)
        let result = d.handleQueryResult(.tabs([tab()]), generation: first.generation, now: at(2))
        #expect(result.events == [.joined(tab())])
    }

    @Test("no new query is requested while checking")
    func noQueryWhileChecking() {
        var d = MeetPresenceDetector()
        _ = d.handleSnapshot(outOnly, now: t0)
        // Input rises while the first query is still in flight.
        #expect(d.handleSnapshot(inOut, now: at(2)).query == nil)
        #expect(d.handleSnapshot(inOut, now: at(10)).query == nil)
    }

    @Test("input off for less than 3 seconds emits nothing")
    func shortInputDropIgnored() {
        var d = joinedDetector()
        #expect(d.handleSnapshot(outOnly, now: at(10)).events.isEmpty)
        #expect(d.handleSnapshot(outOnly, now: at(12)).events.isEmpty)
        #expect(d.handleSnapshot(inOut, now: at(12.5)).events.isEmpty)
        // Back to normal: a later drop restarts the 3s window.
        #expect(d.handleSnapshot(outOnly, now: at(20)).events.isEmpty)
        #expect(d.handleSnapshot(outOnly, now: at(22.9)).events.isEmpty)
    }

    @Test("input off for 3 seconds emits left")
    func inputDropLeaves() {
        var d = joinedDetector()
        _ = d.handleSnapshot(outOnly, now: at(10))
        #expect(d.handleSnapshot(outOnly, now: at(13)).events == [.left(code: "abc-defg-hij")])
        #expect(!d.isInMeeting)
    }

    @Test("a join that never had input leaves when output stops")
    func outputOnlyJoin() {
        var d = joinedDetector(audio: outOnly)
        #expect(d.handleSnapshot(outOnly, now: at(10)).events.isEmpty)
        _ = d.handleSnapshot(silent, now: at(11))
        #expect(d.handleSnapshot(silent, now: at(14)).events == [.left(code: "abc-defg-hij")])
    }

    @Test("mute does not leave (input stays on)")
    func muteIsNotLeave() {
        var d = joinedDetector()
        for s in stride(from: 1.0, through: 60.0, by: 1.0) {
            #expect(d.handleSnapshot(inOut, now: at(s)).events.isEmpty)
        }
        #expect(d.isInMeeting)
    }

    @Test("already in a meeting on the first snapshot counts as a rise")
    func firstSnapshotInMeeting() {
        var d = MeetPresenceDetector()
        #expect(d.handleSnapshot(inOut, now: t0).query != nil)
    }

    @Test("tab choice: active first, then not-just-left, then order")
    func tabSelection() {
        // Active tab wins over a non-active one.
        var d = MeetPresenceDetector()
        var request = d.handleSnapshot(inOut, now: t0).query!
        var result = d.handleQueryResult(.tabs([tab("aaa-aaaa-aaa", active: false), tab("bbb-bbbb-bbb", active: true)]), generation: request.generation, now: at(1))
        #expect(result.events == [.joined(tab("bbb-bbbb-bbb", active: true))])

        // Leave bbb, then rejoin with two non-active tabs: the one just left is deprioritised.
        _ = d.handleSnapshot(silent, now: at(10))
        #expect(d.handleSnapshot(silent, now: at(13)).events == [.left(code: "bbb-bbbb-bbb")])
        request = d.handleSnapshot(inOut, now: at(20)).query!
        result = d.handleQueryResult(.tabs([tab("bbb-bbbb-bbb", active: false), tab("ccc-cccc-ccc", active: false)]), generation: request.generation, now: at(21))
        #expect(result.events == [.joined(tab("ccc-cccc-ccc", active: false))])
    }

    @Test("tab choice falls back to the first tab")
    func tabFallbackFirst() {
        var d = MeetPresenceDetector()
        let request = d.handleSnapshot(inOut, now: t0).query!
        let result = d.handleQueryResult(.tabs([tab("aaa-aaaa-aaa", active: false), tab("bbb-bbbb-bbb", active: false)]), generation: request.generation, now: at(1))
        #expect(result.events == [.joined(tab("aaa-aaaa-aaa", active: false))])
    }
}
