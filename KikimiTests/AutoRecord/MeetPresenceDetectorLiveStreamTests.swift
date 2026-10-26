import Foundation
import Testing

@testable import Kikimi

/// A waiting room that turns into a live stream viewer page (`docs/design/50-meet-auto-record.md` section 2.3,
/// "ライブストリーム"): the mic closes but Chrome keeps playing.
@Suite("MeetPresenceDetector live stream")
struct MeetPresenceDetectorLiveStreamTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let silent = ChromeAudioActivity.silent
    private let inOut = ChromeAudioActivity(input: true, output: true)
    private let outOnly = ChromeAudioActivity(input: false, output: true)

    private let lobby = MeetTab(code: "abc-defg-hij", title: "全社定例", isActive: true, isFrontmost: true)
    private let stream = MeetTab(
        code: "stream/0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d", title: "全社定例", isActive: true, isFrontmost: true
    )

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    /// Joined the waiting room at t0, then the mic closed at 1s and stayed closed; returns the output of the
    /// snapshot that emitted `left`.
    private func leaveLobbyWhilePlaying(_ d: inout MeetPresenceDetector) -> MeetPresenceDetector.Output {
        let first = d.handleSnapshot(inOut, now: t0)
        _ = d.handleQueryResult(.tabs([lobby]), generation: first.query!.generation, now: t0)
        _ = d.handleSnapshot(outOnly, now: at(1))
        _ = d.handleSnapshot(outOnly, now: at(2))
        _ = d.handleSnapshot(outOnly, now: at(3))
        return d.handleSnapshot(outOnly, now: at(4))
    }

    @Test("leaving while Chrome still plays looks at the tabs right away and joins the stream")
    func joinsStreamAfterLobby() throws {
        var d = MeetPresenceDetector()
        let leave = leaveLobbyWhilePlaying(&d)
        #expect(leave.events == [.left(code: lobby.code)])
        let query = try #require(leave.query)
        let result = d.handleQueryResult(.tabs([stream]), generation: query.generation, now: at(5))
        #expect(result.events == [.joined(stream)])
    }

    @Test("the left meeting's lingering tab is not a rejoin")
    func leftTabIsIgnored() throws {
        var d = MeetPresenceDetector()
        let leave = leaveLobbyWhilePlaying(&d)
        let result = d.handleQueryResult(.tabs([lobby]), generation: leave.query!.generation, now: at(5))
        #expect(result.events.isEmpty)
        // Retries keep ignoring it.
        let retry = try #require(d.handleSnapshot(outOnly, now: at(9)).query)
        #expect(d.handleQueryResult(.tabs([lobby]), generation: retry.generation, now: at(9.5)).events.isEmpty)
    }

    @Test("opening the mic again makes the left meeting a rejoin")
    func micReopenRejoins() throws {
        var d = MeetPresenceDetector()
        let leave = leaveLobbyWhilePlaying(&d)
        _ = d.handleQueryResult(.tabs([lobby]), generation: leave.query!.generation, now: at(5))
        _ = d.handleSnapshot(inOut, now: at(6))
        let retry = try #require(d.handleSnapshot(inOut, now: at(9)).query)
        #expect(d.handleQueryResult(.tabs([lobby]), generation: retry.generation, now: at(9.5)).events == [.joined(lobby)])
    }

    @Test("leaving after the audio stopped goes idle without a query")
    func quietLeaveStaysIdle() {
        var d = MeetPresenceDetector()
        let first = d.handleSnapshot(inOut, now: t0)
        _ = d.handleQueryResult(.tabs([lobby]), generation: first.query!.generation, now: t0)
        _ = d.handleSnapshot(silent, now: at(1))
        let leave = d.handleSnapshot(silent, now: at(4))
        #expect(leave.events == [.left(code: lobby.code)])
        #expect(leave.query == nil)
    }

    @Test("a stream is left when its output stops, even if the mic opened meanwhile")
    func streamLeavesOnOutput() {
        var d = MeetPresenceDetector()
        let leave = leaveLobbyWhilePlaying(&d)
        _ = d.handleQueryResult(.tabs([stream]), generation: leave.query!.generation, now: at(5))
        // Mic use elsewhere in Chrome, then it closes again: still watching the stream.
        _ = d.handleSnapshot(inOut, now: at(6))
        for second in 7...12 {
            #expect(d.handleSnapshot(outOnly, now: at(TimeInterval(second))).events.isEmpty)
        }
        _ = d.handleSnapshot(silent, now: at(20))
        #expect(d.handleSnapshot(silent, now: at(23)).events == [.left(code: stream.code)])
    }
}
