import Combine
import Foundation

@testable import Kikimi

/// Manually advanced clock: `sleep(until:)` suspends until `advance(by:)` moves `now` past the deadline.
@MainActor
final class ManualAutoRecordClock: AutoRecordClock {
    private(set) var now: Date
    private var waiters: [UUID: (deadline: Date, continuation: CheckedContinuation<Void, Error>)] = [:]

    init(start: Date = Date(timeIntervalSince1970: 2_000_000)) {
        now = start
    }

    var sleeperCount: Int { waiters.count }

    func sleep(until deadline: Date) async throws {
        if deadline <= now { return }
        let key = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[key] = (deadline, continuation)
                }
            }
        } onCancel: {
            Task { @MainActor in
                if let waiter = self.waiters.removeValue(forKey: key) {
                    waiter.continuation.resume(throwing: CancellationError())
                }
            }
        }
    }

    func advance(by seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
        for (key, waiter) in waiters where waiter.deadline <= now {
            waiters.removeValue(forKey: key)
            waiter.continuation.resume()
        }
    }
}

/// Fake view model. Each operation passes through its in-flight state (`.pausing` ...) like the real one.
@MainActor
final class FakeAutoRecordWorkspace: AutoRecordWorkspace {
    let sessionId: String
    private let subject: CurrentValueSubject<RecordingButtonState, Never>
    var hasConfirmedTranscript = true
    var onBannerAction: ((WorkspaceBanner, BannerActionID) -> Void)?
    private(set) var banners: [WorkspaceBanner] = []
    private(set) var calls: [String] = []

    /// Final state after each operation; set to an in-flight state to simulate a failure.
    var pauseOutcome: RecordingButtonState = .paused(elapsedSeconds: 10)
    var resumeOutcome: RecordingButtonState = .recording(elapsedSeconds: 10)
    var endOutcome: RecordingButtonState = .ended

    init(sessionId: String, state: RecordingButtonState) {
        self.sessionId = sessionId
        subject = CurrentValueSubject(state)
    }

    var recordingButtonState: RecordingButtonState { subject.value }
    var recordingButtonStatePublisher: AnyPublisher<RecordingButtonState, Never> { subject.eraseToAnyPublisher() }

    func count(_ call: String) -> Int { calls.filter { $0 == call }.count }

    func pauseRecording() async {
        calls.append("pause")
        subject.send(.pausing)
        await Task.yield()
        subject.send(pauseOutcome)
    }

    func resumeRecording() async {
        calls.append("resume")
        subject.send(.resuming)
        await Task.yield()
        subject.send(resumeOutcome)
    }

    func endMeeting() async {
        calls.append("end")
        subject.send(.ending)
        await Task.yield()
        subject.send(endOutcome)
    }

    @discardableResult
    func discardAutoRecordedSession() async -> Bool {
        calls.append("discard")
        subject.send(.discarding)
        return true
    }

    func showBanner(_ banner: WorkspaceBanner) {
        banners.removeAll { $0.id == banner.id }
        banners.append(banner)
    }

    func removeBanners(withId id: String) {
        banners.removeAll { $0.id == id }
    }

    // MARK: User actions (not flagged by the coordinator)

    func userPause() {
        subject.send(.pausing)
        subject.send(.paused(elapsedSeconds: 5))
    }

    func userResume() {
        subject.send(.resuming)
        subject.send(.recording(elapsedSeconds: 5))
    }

    func userEnd() {
        subject.send(.ending)
        subject.send(.ended)
    }

    func hasBanner(_ id: String) -> Bool { banners.contains { $0.id == id } }
}

@MainActor
final class FakeAutoRecordProvider: AutoRecordWorkspaceProviding {
    var recordingSessionId: String?
    var startOutcome: RecordingButtonState = .recording(elapsedSeconds: 0)
    var openError: Error?
    private(set) var workspaces: [String: FakeAutoRecordWorkspace] = [:]
    private(set) var quickRecordOverrides: [DraftMetaOverrides] = []
    private(set) var reopenCount = 0
    private var closedSnapshots: [String: (RecordingButtonState, Bool)] = [:]
    private var nextIndex = 1

    func quickRecord(overrides: DraftMetaOverrides) async throws -> AutoRecordWorkspace {
        quickRecordOverrides.append(overrides)
        let workspace = FakeAutoRecordWorkspace(sessionId: "session-\(nextIndex)", state: startOutcome)
        nextIndex += 1
        workspaces[workspace.sessionId] = workspace
        return workspace
    }

    func workspace(for sessionId: String) async throws -> AutoRecordWorkspace {
        if let openError { throw openError }
        if let existing = workspaces[sessionId] { return existing }
        guard let snapshot = closedSnapshots[sessionId] else { throw CocoaError(.fileNoSuchFile) }
        reopenCount += 1
        let reopened = FakeAutoRecordWorkspace(sessionId: sessionId, state: snapshot.0)
        reopened.hasConfirmedTranscript = snapshot.1
        workspaces[sessionId] = reopened
        return reopened
    }

    /// Simulates the user closing the Session Window of a Paused session.
    func closeWindow(of sessionId: String) {
        guard let workspace = workspaces.removeValue(forKey: sessionId) else { return }
        closedSnapshots[sessionId] = (workspace.recordingButtonState, workspace.hasConfirmedTranscript)
    }
}

/// Scripted `ChromeAudioActivitySource`.
final class FakeChromeAudioSource: ChromeAudioActivitySource {
    private var handler: ((ChromeAudioActivity) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start(handler: @escaping (ChromeAudioActivity) -> Void) {
        startCount += 1
        self.handler = handler
    }

    func stop() {
        stopCount += 1
        handler = nil
    }

    /// Delivers a snapshot as the real source does (on the main thread). No-op while stopped.
    func emit(_ activity: ChromeAudioActivity) {
        handler?(activity)
    }
}
