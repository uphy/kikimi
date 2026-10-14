import Foundation
import Testing

@testable import Kikimi

/// `docs/design/50-meet-auto-record.md` section 3.6 / 10: presentation and macOS notifications, with a
/// fake provider and notifier.
@MainActor
@Suite("MeetAutoRecordCoordinator notifications")
struct MeetAutoRecordCoordinatorNotificationTests {
    private let provider = FakeAutoRecordProvider()
    private let clock = ManualAutoRecordClock()
    private let notifier = FakeAutoRecordNotifier()

    private func makeCoordinator(
        grace: Int = 120,
        presentation: WorkspacePresentation = .stowed
    ) -> MeetAutoRecordCoordinator {
        MeetAutoRecordCoordinator(
            provider: provider, clock: clock, graceSeconds: { grace },
            notifier: notifier, presentation: { presentation }
        )
    }

    private func tab(_ code: String = "abc-defg-hij", title: String = "Weekly sync") -> MeetTab {
        MeetTab(code: code, title: title, isActive: true)
    }

    private func eventually(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { await Task.yield() }
    }

    private func join(_ coordinator: MeetAutoRecordCoordinator) async -> FakeAutoRecordWorkspace {
        await coordinator.handle(.joined(tab()))
        return provider.workspaces[coordinator.currentSessionId ?? ""]!
    }

    /// Joins, then leaves; returns the workspace paused with a pending end.
    private func joinAndLeave(_ coordinator: MeetAutoRecordCoordinator) async -> FakeAutoRecordWorkspace {
        let workspace = await join(coordinator)
        await coordinator.handle(.left(code: "abc-defg-hij"))
        return workspace
    }

    @Test("stowed config starts stowed and posts the start notification with the title")
    func stowedStart() async {
        let coordinator = makeCoordinator(presentation: .stowed)
        let workspace = await join(coordinator)
        #expect(provider.quickRecordPresentations == [.stowed])
        let posted = notifier.posted.first
        #expect(posted?.kind == .started)
        #expect(posted?.sessionId == workspace.sessionId)
        #expect(posted?.title == "Weekly sync")
        #expect(posted?.body.contains("Weekly sync") == true)
    }

    @Test("shown config starts with the window shown")
    func shownStart() async {
        let coordinator = makeCoordinator(presentation: .shown)
        _ = await join(coordinator)
        #expect(provider.quickRecordPresentations == [.shown])
    }

    @Test("the start notification is removed after 60 seconds")
    func startNotificationExpires() async {
        let coordinator = makeCoordinator()
        let workspace = await join(coordinator)
        await Task.yield()
        clock.advance(by: 59)
        await Task.yield()
        #expect(!notifier.wasRemoved(.started, sessionId: workspace.sessionId))
        clock.advance(by: 2)
        await eventually { notifier.wasRemoved(.started, sessionId: workspace.sessionId) }
        #expect(notifier.wasRemoved(.started, sessionId: workspace.sessionId))
    }

    @Test("leaving posts the end-scheduled notification with the deadline")
    func leavePosts() async {
        let coordinator = makeCoordinator(grace: 120)
        let workspace = await joinAndLeave(coordinator)
        let scheduled = notifier.posted.last { $0.kind == .endScheduled }
        #expect(scheduled?.sessionId == workspace.sessionId)
        #expect(scheduled?.deadline == clock.now.addingTimeInterval(120))
    }

    @Test("rejoining removes the end-scheduled notification")
    func rejoinRemoves() async {
        let coordinator = makeCoordinator()
        let workspace = await joinAndLeave(coordinator)
        await coordinator.handle(.joined(tab()))
        #expect(notifier.wasRemoved(.endScheduled, sessionId: workspace.sessionId))
    }

    @Test("the keep-open action removes the notification and stops the auto end")
    func keepOpenAction() async {
        let coordinator = makeCoordinator()
        let workspace = await joinAndLeave(coordinator)
        coordinator.handleBannerAction(sessionId: workspace.sessionId, action: .keepMeetingOpen)
        #expect(coordinator.managed.isEmpty)
        #expect(notifier.wasRemoved(.endScheduled, sessionId: workspace.sessionId))
    }

    @Test("expiry with transcript ends the meeting, removes the pending notice and posts 'ended'")
    func expiryEnds() async {
        let coordinator = makeCoordinator(grace: 60)
        let workspace = await joinAndLeave(coordinator)
        workspace.hasConfirmedTranscript = true
        await Task.yield()
        clock.advance(by: 61)
        await eventually { workspace.count("end") == 1 && notifier.postedKinds(for: workspace.sessionId).contains(.ended) }
        #expect(workspace.count("end") == 1)
        #expect(notifier.wasRemoved(.endScheduled, sessionId: workspace.sessionId))
        #expect(notifier.postedKinds(for: workspace.sessionId).last == .ended)
    }

    @Test("expiry without transcript discards and posts 'discarded'")
    func expiryDiscards() async {
        let coordinator = makeCoordinator(grace: 60)
        let workspace = await joinAndLeave(coordinator)
        workspace.hasConfirmedTranscript = false
        await Task.yield()
        clock.advance(by: 61)
        await eventually { notifier.postedKinds(for: workspace.sessionId).contains(.discarded) }
        #expect(workspace.count("discard") == 1)
        #expect(workspace.count("end") == 0)
        #expect(notifier.postedKinds(for: workspace.sessionId).last == .discarded)
    }

    @Test("the cancel action behaves like the banner button: discards and removes notifications")
    func cancelAction() async {
        let coordinator = makeCoordinator()
        let workspace = await join(coordinator)
        coordinator.handleBannerAction(sessionId: workspace.sessionId, action: .cancelAutoRecord)
        await eventually { workspace.count("discard") == 1 }
        #expect(workspace.count("discard") == 1)
        await eventually { coordinator.managed.isEmpty }
        #expect(coordinator.managed.isEmpty)
        #expect(notifier.wasRemoved(.started, sessionId: workspace.sessionId))
    }

    @Test("reopening a closed window at expiry uses the configured presentation")
    func reopenUsesPresentation() async {
        let coordinator = makeCoordinator(grace: 60, presentation: .stowed)
        let workspace = await joinAndLeave(coordinator)
        provider.closeWindow(of: workspace.sessionId)
        await Task.yield()
        clock.advance(by: 61)
        await eventually { provider.reopenCount == 1 }
        #expect(provider.reopenPresentations == [.stowed])
    }

    @Test("a start that does not reach recording shows the window and posts 'startFailed'")
    func startFailureIsVisible() async {
        provider.startOutcome = .startRecording
        let coordinator = makeCoordinator(presentation: .stowed)
        await coordinator.handle(.joined(tab()))
        #expect(coordinator.managed.isEmpty)
        #expect(provider.shownWindows == ["session-1"])
        #expect(notifier.postedKinds(for: "session-1") == [.startFailed])
    }

    @Test("an auto end closes the window if it is still stowed")
    func expiryClosesStowedWindow() async {
        let coordinator = makeCoordinator(grace: 60)
        let workspace = await joinAndLeave(coordinator)
        workspace.hasConfirmedTranscript = true
        await Task.yield()
        clock.advance(by: 61)
        await eventually { provider.closedIfStowed == [workspace.sessionId] }
        #expect(provider.closedIfStowed == [workspace.sessionId])
    }

    @Test("leaving with auto end disabled posts 'pausedNoAutoEnd'")
    func graceZeroNotifies() async {
        let coordinator = makeCoordinator(grace: 0)
        let workspace = await joinAndLeave(coordinator)
        #expect(workspace.count("pause") == 1)
        #expect(notifier.postedKinds(for: workspace.sessionId).last == .pausedNoAutoEnd)
    }
}
