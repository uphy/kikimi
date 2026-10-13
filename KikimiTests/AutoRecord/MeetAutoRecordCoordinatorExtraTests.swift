import Foundation
import Testing

@testable import Kikimi

/// Gaps left by `MeetAutoRecordCoordinatorTests`: config binding, window reopen, rejoin fallback,
/// placeholder titles and the system clock.
@MainActor
@Suite("MeetAutoRecordCoordinator extras")
struct MeetAutoRecordCoordinatorExtraTests {
    private let provider = FakeAutoRecordProvider()
    private let clock = ManualAutoRecordClock()

    private func makeCoordinator(
        grace: Int = 120, monitor: MeetPresenceMonitor? = nil
    ) -> MeetAutoRecordCoordinator {
        MeetAutoRecordCoordinator(provider: provider, clock: clock, graceSeconds: { grace }, monitor: monitor)
    }

    private func tab(_ code: String = "abc-defg-hij", title: String = "Weekly sync") -> MeetTab {
        MeetTab(code: code, title: title, isActive: true)
    }

    @Test("placeholder titles (empty, whitespace, Meet, code in any case) leave the title empty")
    func placeholderTitles() {
        for title in ["", "   \n", "Meet", "meet", "ABC-DEFG-HIJ"] {
            let overrides = MeetAutoRecordCoordinator.overrides(for: tab(title: title))
            #expect(overrides.title == nil, "title \(title.debugDescription)")
            #expect(!overrides.titleAutoNamedOnce)
        }
    }

    @Test("a real title is trimmed and marked as auto-named")
    func realTitleTrimmed() {
        let overrides = MeetAutoRecordCoordinator.overrides(for: tab(title: "  Design review \n"))
        #expect(overrides.title == "Design review")
        #expect(overrides.titleAutoNamedOnce)
    }

    @Test("startMonitoring and stopMonitoring drive the monitor")
    func monitoringLifecycle() {
        let audio = FakeChromeAudioSource()
        let coordinator = makeCoordinator(monitor: MeetPresenceMonitor(audioMonitor: audio, inspector: FakeTabInspector()))
        #expect(!coordinator.isMonitoring)
        coordinator.startMonitoring()
        #expect(coordinator.isMonitoring)
        #expect(audio.startCount == 1)
        coordinator.stopMonitoring()
        #expect(!coordinator.isMonitoring)
        #expect(audio.stopCount == 1)
    }

    @Test("bind(to:) follows auto_record.google_meet.enabled")
    func bindFollowsConfig() async {
        let audio = FakeChromeAudioSource()
        let coordinator = makeCoordinator(monitor: MeetPresenceMonitor(audioMonitor: audio, inspector: FakeTabInspector()))
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("coordinator-bind-\(UUID().uuidString)", isDirectory: true)
        let config = AppConfig(directory: dir, credentialStore: InMemoryCredentialStore())
        config.update { $0.autoRecord.googleMeet.enabled = false }
        coordinator.bind(to: config)
        for _ in 0..<50 { await Task.yield() }
        #expect(!coordinator.isMonitoring)

        config.update { $0.autoRecord.googleMeet.enabled = true }
        for _ in 0..<500 where !coordinator.isMonitoring { await Task.yield() }
        #expect(coordinator.isMonitoring)

        config.update { $0.autoRecord.googleMeet.enabled = false }
        for _ in 0..<500 where coordinator.isMonitoring { await Task.yield() }
        #expect(!coordinator.isMonitoring)
    }

    @Test("workspaceDidOpen re-attaches a managed session and shows the end banner")
    func workspaceDidOpenReattaches() async {
        let coordinator = makeCoordinator()
        await coordinator.handle(.joined(tab()))
        let id = coordinator.currentSessionId!
        await coordinator.handle(.left(code: "abc-defg-hij"))
        provider.closeWindow(of: id)

        let reopened = FakeAutoRecordWorkspace(sessionId: id, state: .paused(elapsedSeconds: 3))
        coordinator.workspaceDidOpen(sessionId: id, viewModel: reopened)
        #expect(reopened.hasBanner("autoRecordEndScheduled"))
        #expect(reopened.onBannerAction != nil)

        // A user action on the re-attached workspace releases the session.
        reopened.userResume()
        #expect(coordinator.managed.isEmpty)
    }

    @Test("workspaceDidOpen ignores sessions that are not managed")
    func workspaceDidOpenIgnoresUnmanaged() {
        let coordinator = makeCoordinator()
        let other = FakeAutoRecordWorkspace(sessionId: "unmanaged", state: .recording(elapsedSeconds: 1))
        coordinator.workspaceDidOpen(sessionId: "unmanaged", viewModel: other)
        #expect(other.onBannerAction == nil)
        #expect(other.banners.isEmpty)
    }

    @Test("rejoin with an unreachable workspace drops the entry and starts a fresh session")
    func rejoinFallsBackToNewSession() async {
        let coordinator = makeCoordinator()
        await coordinator.handle(.joined(tab()))
        let first = coordinator.currentSessionId!
        await coordinator.handle(.left(code: "abc-defg-hij"))
        provider.openError = CocoaError(.fileReadNoSuchFile)
        await coordinator.handle(.joined(tab()))
        #expect(coordinator.managed[first] == nil)
        #expect(provider.quickRecordOverrides.count == 2)
        #expect(coordinator.currentSessionId != first)
        #expect(coordinator.currentSessionId != nil)
    }

    @Test("a different meeting code does not resume the paused session")
    func differentCodeStartsNew() async {
        let coordinator = makeCoordinator()
        await coordinator.handle(.joined(tab()))
        let first = coordinator.currentSessionId!
        await coordinator.handle(.left(code: "abc-defg-hij"))
        await coordinator.handle(.joined(tab("zzz-yyyy-xxx")))
        #expect(provider.workspaces[first]?.count("resume") == 0)
        #expect(provider.quickRecordOverrides.count == 2)
        #expect(coordinator.managed[first] != nil)
    }

    @Test("discard on an unmanaged session is a no-op")
    func discardUnmanaged() async {
        let coordinator = makeCoordinator()
        await coordinator.discard(sessionId: "nope")
        #expect(coordinator.managed.isEmpty)
    }

    @Test("SystemAutoRecordClock returns immediately for a past deadline and waits for a near one")
    func systemClock() async throws {
        let system = SystemAutoRecordClock()
        try await system.sleep(until: Date(timeIntervalSinceNow: -5))
        let start = Date()
        try await system.sleep(until: Date(timeIntervalSinceNow: 0.05))
        #expect(Date().timeIntervalSince(start) >= 0.04)
    }

    @Test("SystemAutoRecordClock.sleep throws on cancellation")
    func systemClockCancel() async {
        let task = Task { @MainActor in
            try await SystemAutoRecordClock().sleep(until: Date(timeIntervalSinceNow: 60))
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
