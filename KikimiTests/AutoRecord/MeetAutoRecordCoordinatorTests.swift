import Foundation
import Testing

@testable import Kikimi

/// `docs/design/50-meet-auto-record.md` section 10: the coordinator against a fake provider/workspace
/// and a manual clock.
@MainActor
@Suite("MeetAutoRecordCoordinator")
struct MeetAutoRecordCoordinatorTests {
    private let provider = FakeAutoRecordProvider()
    private let clock = ManualAutoRecordClock()

    private func makeCoordinator(grace: Int = 120) -> MeetAutoRecordCoordinator {
        MeetAutoRecordCoordinator(provider: provider, clock: clock, graceSeconds: { grace })
    }

    private func tab(_ code: String = "abc-defg-hij", title: String = "Weekly sync") -> MeetTab {
        MeetTab(code: code, title: title, isActive: true)
    }

    private func eventually(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { await Task.yield() }
    }

    /// Joins and returns the started session's fake workspace.
    private func join(_ coordinator: MeetAutoRecordCoordinator, _ meetTab: MeetTab? = nil) async -> FakeAutoRecordWorkspace {
        await coordinator.handle(.joined(meetTab ?? tab()))
        return provider.workspaces[coordinator.currentSessionId ?? ""]!
    }

    @Test("joining while a manual recording is running does nothing")
    func manualRecordingWins() async {
        let coordinator = makeCoordinator()
        provider.recordingSessionId = "manual"
        await coordinator.handle(.joined(tab()))
        #expect(provider.quickRecordOverrides.isEmpty)
        #expect(coordinator.managed.isEmpty)
    }

    @Test("joining starts a session with the Meet title and provenance, and shows the banner")
    func joinStarts() async {
        let coordinator = makeCoordinator()
        let workspace = await join(coordinator)
        #expect(coordinator.managed.count == 1)
        let overrides = provider.quickRecordOverrides[0]
        #expect(overrides.title == "Weekly sync")
        #expect(overrides.titleAutoNamedOnce)
        #expect(overrides.autoRecord == AutoRecordMeta(source: .googleMeet, meetingCode: "abc-defg-hij"))
        #expect(workspace.hasBanner("autoRecordStarted"))
    }

    @Test("a tab titled with just the meeting code leaves the title empty")
    func codeOnlyTitle() {
        let overrides = MeetAutoRecordCoordinator.overrides(for: tab(title: "abc-defg-hij"))
        #expect(overrides.title == nil)
        #expect(!overrides.titleAutoNamedOnce)
    }

    @Test("the start banner disappears after 60 seconds but the session stays managed")
    func startBannerExpires() async {
        let coordinator = makeCoordinator()
        let workspace = await join(coordinator)
        await Task.yield()
        clock.advance(by: 59)
        await Task.yield()
        #expect(workspace.hasBanner("autoRecordStarted"))
        clock.advance(by: 2)
        await eventually { !workspace.hasBanner("autoRecordStarted") }
        #expect(!workspace.hasBanner("autoRecordStarted"))
        #expect(coordinator.managed.count == 1)
    }

    @Test("a start that does not reach Recording is not managed")
    func startFailure() async {
        let coordinator = makeCoordinator()
        provider.startOutcome = .startRecording
        await coordinator.handle(.joined(tab()))
        #expect(provider.quickRecordOverrides.count == 1)
        #expect(coordinator.managed.isEmpty)
        #expect(coordinator.currentSessionId == nil)
    }

    @Test("leave pauses, and the grace period ends the meeting")
    func leaveThenEnd() async {
        let coordinator = makeCoordinator()
        let workspace = await join(coordinator)
        await coordinator.handle(.left(code: "abc-defg-hij"))
        #expect(workspace.count("pause") == 1)
        #expect(workspace.hasBanner("autoRecordEndScheduled"))
        #expect(coordinator.managed[workspace.sessionId]?.pausedByCoordinator == true)

        await Task.yield()
        clock.advance(by: 119)
        await Task.yield()
        #expect(workspace.count("end") == 0)
        clock.advance(by: 2)
        await eventually { workspace.count("end") == 1 }
        #expect(workspace.count("end") == 1)
        #expect(workspace.count("discard") == 0)
        #expect(coordinator.managed.isEmpty)
    }

    @Test("an expired session with no confirmed transcript is discarded instead of ended")
    func expiryWithoutTranscriptDiscards() async {
        let coordinator = makeCoordinator()
        let workspace = await join(coordinator)
        workspace.hasConfirmedTranscript = false
        await coordinator.handle(.left(code: "abc-defg-hij"))
        await Task.yield()
        clock.advance(by: 121)
        await eventually { workspace.count("discard") == 1 }
        #expect(workspace.count("discard") == 1)
        #expect(workspace.count("end") == 0)
    }

    @Test("rejoining the same meeting within the grace period resumes and cancels the end")
    func rejoinResumes() async {
        let coordinator = makeCoordinator()
        let workspace = await join(coordinator)
        await coordinator.handle(.left(code: "abc-defg-hij"))
        await Task.yield()
        clock.advance(by: 30)
        await coordinator.handle(.joined(tab()))
        #expect(workspace.count("resume") == 1)
        #expect(provider.quickRecordOverrides.count == 1)
        #expect(coordinator.managed[workspace.sessionId]?.phase == .recording)
        #expect(coordinator.managed[workspace.sessionId]?.pausedByCoordinator == false)
        #expect(!workspace.hasBanner("autoRecordEndScheduled"))

        clock.advance(by: 300)
        for _ in 0..<20 { await Task.yield() }
        #expect(workspace.count("end") == 0)
    }

    @Test("the coordinator's own pause and resume do not release the session")
    func ownOperationsKeepManagement() async {
        let coordinator = makeCoordinator()
        let workspace = await join(coordinator)
        await coordinator.handle(.left(code: "abc-defg-hij"))
        #expect(coordinator.managed[workspace.sessionId] != nil)
        await coordinator.handle(.joined(tab()))
        #expect(coordinator.managed[workspace.sessionId] != nil)
        #expect(coordinator.currentSessionId == workspace.sessionId)
    }

    @Test("a manual pause releases the session; leave then rejoin never auto-resumes")
    func manualPauseReleases() async {
        let coordinator = makeCoordinator()
        let workspace = await join(coordinator)
        workspace.userPause()
        #expect(coordinator.managed.isEmpty)

        await coordinator.handle(.left(code: "abc-defg-hij"))
        #expect(workspace.count("pause") == 0)
        await coordinator.handle(.joined(tab()))
        #expect(workspace.count("resume") == 0)
    }

    @Test("a manual resume, end, delete or 終了しない releases the session")
    func otherUserActionsRelease() async {
        // Resume after the coordinator paused it.
        var coordinator = makeCoordinator()
        var workspace = await join(coordinator)
        await coordinator.handle(.left(code: "abc-defg-hij"))
        workspace.userResume()
        #expect(coordinator.managed.isEmpty)

        // End.
        coordinator = makeCoordinator()
        workspace = await join(coordinator)
        workspace.userEnd()
        #expect(coordinator.managed.isEmpty)

        // Delete.
        coordinator = makeCoordinator()
        workspace = await join(coordinator)
        coordinator.sessionDidDisappear(workspace.sessionId)
        #expect(coordinator.managed.isEmpty)

        // 終了しない.
        coordinator = makeCoordinator()
        workspace = await join(coordinator)
        await coordinator.handle(.left(code: "abc-defg-hij"))
        workspace.onBannerAction?(.autoRecordEndScheduled(deadline: clock.now), .keepMeetingOpen)
        #expect(coordinator.managed.isEmpty)
        #expect(!workspace.hasBanner("autoRecordEndScheduled"))
        clock.advance(by: 500)
        for _ in 0..<20 { await Task.yield() }
        #expect(workspace.count("end") == 0)
    }

    @Test("取り消す discards the session and releases it")
    func cancelButtonDiscards() async {
        let coordinator = makeCoordinator()
        let workspace = await join(coordinator)
        workspace.onBannerAction?(.autoRecordStarted(sessionId: workspace.sessionId), .cancelAutoRecord)
        await eventually { workspace.count("discard") == 1 }
        #expect(workspace.count("discard") == 1)
        await eventually { coordinator.managed.isEmpty }
        #expect(coordinator.managed.isEmpty)
    }

    @Test("end_grace_seconds 0 leaves the session Paused and unmanaged")
    func zeroGraceStaysPaused() async {
        let coordinator = makeCoordinator(grace: 0)
        let workspace = await join(coordinator)
        await coordinator.handle(.left(code: "abc-defg-hij"))
        #expect(workspace.count("pause") == 1)
        #expect(coordinator.managed.isEmpty)
        #expect(!workspace.hasBanner("autoRecordEndScheduled"))
        clock.advance(by: 1000)
        for _ in 0..<20 { await Task.yield() }
        #expect(workspace.count("end") == 0)
    }

    @Test("joining another meeting does not stop the previous session's timer")
    func previousTimerKeepsRunning() async {
        let coordinator = makeCoordinator()
        let first = await join(coordinator)
        await coordinator.handle(.left(code: "abc-defg-hij"))
        await Task.yield()
        clock.advance(by: 20)

        let second = await join(coordinator, tab("xyz-wxyz-xyz", title: "Other"))
        #expect(second.sessionId != first.sessionId)
        #expect(coordinator.currentSessionId == second.sessionId)
        #expect(coordinator.managed.count == 2)

        clock.advance(by: 101)
        await eventually { first.count("end") == 1 }
        #expect(first.count("end") == 1)
        #expect(second.count("end") == 0)
        #expect(coordinator.managed[second.sessionId] != nil)
    }

    @Test("a closed window is reopened to end the meeting")
    func closedWindowIsReopened() async {
        let coordinator = makeCoordinator()
        let workspace = await join(coordinator)
        let id = workspace.sessionId
        await coordinator.handle(.left(code: "abc-defg-hij"))
        await Task.yield()
        provider.closeWindow(of: id)

        clock.advance(by: 121)
        await eventually { provider.workspaces[id]?.count("end") == 1 }
        #expect(provider.reopenCount == 1)
        #expect(provider.workspaces[id]?.count("end") == 1)
    }

    @Test("a failed pause releases the session")
    func pauseFailureReleases() async {
        let coordinator = makeCoordinator()
        let workspace = await join(coordinator)
        workspace.pauseOutcome = .pausing
        await coordinator.handle(.left(code: "abc-defg-hij"))
        #expect(coordinator.managed.isEmpty)
    }

    @Test("a failed resume releases the session and leaves it Paused")
    func resumeFailureReleases() async {
        let coordinator = makeCoordinator()
        let workspace = await join(coordinator)
        await coordinator.handle(.left(code: "abc-defg-hij"))
        workspace.resumeOutcome = .paused(elapsedSeconds: 10)
        await coordinator.handle(.joined(tab()))
        #expect(coordinator.managed.isEmpty)
        #expect(provider.quickRecordOverrides.count == 1)
    }

    @Test("an unopenable workspace at expiry is logged and nothing is ended")
    func openFailureAtExpiry() async {
        let coordinator = makeCoordinator()
        let workspace = await join(coordinator)
        await coordinator.handle(.left(code: "abc-defg-hij"))
        await Task.yield()
        provider.openError = CocoaError(.fileNoSuchFile)
        clock.advance(by: 121)
        await eventually { coordinator.managed.isEmpty }
        #expect(coordinator.managed.isEmpty)
        #expect(workspace.count("end") == 0)
    }

    @Test("leave for a meeting that is not the current one is ignored")
    func leaveWrongCode() async {
        let coordinator = makeCoordinator()
        let workspace = await join(coordinator)
        await coordinator.handle(.left(code: "zzz-zzzz-zzz"))
        #expect(workspace.count("pause") == 0)
    }

    @Test("queued events are processed in order")
    func submitOrdersEvents() async {
        let coordinator = makeCoordinator()
        coordinator.submit(.joined(tab()))
        coordinator.submit(.left(code: "abc-defg-hij"))
        await coordinator.waitUntilIdle()
        let workspace = provider.workspaces.values.first
        #expect(workspace?.count("pause") == 1)
    }
}
