import Combine
import Foundation
import OSLog

// MARK: - Clock

/// Time source for the coordinator's timers. Injected so tests never wait in real time.
@MainActor
protocol AutoRecordClock {
    var now: Date { get }
    /// Returns once `now >= deadline`; throws `CancellationError` if the calling task is cancelled.
    func sleep(until deadline: Date) async throws
}

@MainActor
struct SystemAutoRecordClock: AutoRecordClock {
    var now: Date { Date() }

    func sleep(until deadline: Date) async throws {
        // Loop: a wake-up slightly before the deadline (clock adjustment) must not fire the timer early.
        while true {
            let interval = deadline.timeIntervalSince(Date())
            guard interval > 0 else { return }
            try await Task.sleep(for: .seconds(interval))
        }
    }
}

// MARK: - ManagedSession

/// An auto-recorded session the coordinator still operates on (`docs/design/50-meet-auto-record.md` section 3.0).
struct ManagedSession {
    enum Phase: Equatable {
        case recording
        case pausedAwaitingEnd(deadline: Date)
        /// Paused with no automatic end (`end_grace_seconds == 0`, or a failed resume). Transient: the
        /// entry is dropped right after.
        case pausedNoAutoEnd
    }

    let sessionId: String
    let meetingCode: String
    var phase: Phase
    /// True only while the session is paused by the coordinator itself.
    var pausedByCoordinator: Bool
    var endTimer: Task<Void, Never>?
    /// When the "recording started / 取り消す" banner goes away.
    var startBannerDeadline: Date?
    var startBannerTimer: Task<Void, Never>?
}

// MARK: - Coordinator

/// Turns `MeetPresenceMonitor` events into session operations: start on join, pause on leave, end (or
/// discard) after the grace period. Only sessions it started itself are managed, and a session is dropped
/// from management as soon as the user touches it (design 50 sections 3.0 - 3.3).
@MainActor
final class MeetAutoRecordCoordinator {
    static let shared = MeetAutoRecordCoordinator()

    /// How long the "recording started" banner stays (section 3.1).
    static let startBannerDuration: TimeInterval = 60

    private enum Operation {
        case pause, resume, end, discard
    }

    private struct WeakWorkspace {
        weak var value: AutoRecordWorkspace?
    }

    private let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "MeetAutoRecordCoordinator")
    private let provider: AutoRecordWorkspaceProviding
    private let clock: AutoRecordClock
    private let graceSeconds: @MainActor () -> Int
    private let monitor: MeetPresenceMonitor

    private(set) var managed: [String: ManagedSession] = [:]
    private(set) var currentSessionId: String?

    private var operationInFlight: [String: Operation] = [:]
    private var lastState: [String: RecordingButtonState] = [:]
    private var subscriptions: [String: AnyCancellable] = [:]
    private var liveWorkspaces: [String: WeakWorkspace] = [:]

    private var pendingEvents: [MeetPresenceDetector.Event] = []
    private var drainTask: Task<Void, Never>?
    private var configCancellable: AnyCancellable?

    init(
        provider: AutoRecordWorkspaceProviding? = nil,
        clock: AutoRecordClock? = nil,
        graceSeconds: (@MainActor () -> Int)? = nil,
        monitor: MeetPresenceMonitor? = nil
    ) {
        // Defaults are resolved here: default-argument expressions are not main-actor isolated.
        let monitor = monitor ?? MeetPresenceMonitor()
        self.provider = provider ?? WindowManagerAutoRecordProvider()
        self.clock = clock ?? SystemAutoRecordClock()
        self.graceSeconds = graceSeconds ?? { AppConfig.shared.data.autoRecord.googleMeet.endGraceSeconds }
        self.monitor = monitor
        monitor.onEvent = { [weak self] event in self?.submit(event) }
    }

    // MARK: Monitoring lifecycle

    var isMonitoring: Bool { monitor.isMonitoring }

    func startMonitoring() { monitor.start() }
    func stopMonitoring() { monitor.stop() }

    /// Starts/stops monitoring to follow `auto_record.google_meet.enabled`, now and on every change.
    func bind(to config: AppConfig) {
        configCancellable = config.$data
            .map(\.autoRecord.googleMeet.enabled)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if enabled { self.startMonitoring() } else { self.stopMonitoring() }
                }
            }
    }

    // MARK: Event intake

    /// Queues `event`; events are processed strictly one at a time, in order.
    func submit(_ event: MeetPresenceDetector.Event) {
        pendingEvents.append(event)
        guard drainTask == nil else { return }
        drainTask = Task { [self] in
            while !pendingEvents.isEmpty {
                await handle(pendingEvents.removeFirst())
            }
            drainTask = nil
        }
    }

    /// Returns once every queued event has been processed.
    func waitUntilIdle() async {
        while let task = drainTask { await task.value }
    }

    func handle(_ event: MeetPresenceDetector.Event) async {
        switch event {
        case .joined(let tab): await handleJoined(tab)
        case .left(let code): await handleLeft(code: code)
        }
    }

    // MARK: Hooks called by WindowManager

    /// The session was deleted (cancel button, Session List, ...). Section 3.0.3.
    func sessionDidDisappear(_ sessionId: String) {
        removeEntry(sessionId, reason: "session deleted")
    }

    /// A Session Window was (re)opened. Re-subscribes if the session is still managed.
    func workspaceDidOpen(sessionId: String, viewModel: AutoRecordWorkspace) {
        guard managed[sessionId] != nil else { return }
        attach(viewModel)
    }

    // MARK: Join

    private func handleJoined(_ tab: MeetTab) async {
        if let active = provider.recordingSessionId {
            logger.info("auto-record skipped: session \(active, privacy: .public) is already recording (meeting \(tab.code, privacy: .public))")
            return
        }
        let rejoinable = managed.values.first { entry in
            guard entry.meetingCode == tab.code, entry.pausedByCoordinator else { return false }
            if case .pausedAwaitingEnd = entry.phase { return true }
            return false
        }
        if let rejoinable, await resumeAfterRejoin(sessionId: rejoinable.sessionId, code: tab.code) { return }
        await startNewSession(for: tab)
    }

    /// Section 3.1-2. Returns false only when the session could not be reached at all, so the caller
    /// falls back to starting a fresh one.
    private func resumeAfterRejoin(sessionId: String, code: String) async -> Bool {
        managed[sessionId]?.endTimer?.cancel()
        managed[sessionId]?.endTimer = nil
        let workspace: AutoRecordWorkspace
        do {
            workspace = try await provider.workspace(for: sessionId)
        } catch {
            logger.error("auto-resume failed for session \(sessionId, privacy: .public): cannot open workspace: \(String(describing: error), privacy: .public)")
            removeEntry(sessionId, reason: "workspace unavailable")
            return false
        }
        guard managed[sessionId] != nil else { return true }
        attach(workspace)
        await perform(.resume, on: workspace) { await workspace.resumeRecording() }
        guard managed[sessionId] != nil else { return true }

        guard case .recording = workspace.recordingButtonState else {
            logger.warning("auto-resume failed for session \(sessionId, privacy: .public); leaving it Paused")
            managed[sessionId]?.phase = .pausedNoAutoEnd
            removeEntry(sessionId, reason: "resume failed")
            return true
        }
        managed[sessionId]?.phase = .recording
        managed[sessionId]?.pausedByCoordinator = false
        workspace.removeBanners(withId: WorkspaceBanner.autoRecordEndScheduled(deadline: .distantPast).id)
        currentSessionId = sessionId
        logger.info("auto-resumed session \(sessionId, privacy: .public): rejoined meeting \(code, privacy: .public)")
        return true
    }

    /// Section 3.1-3 / 3.1-4.
    private func startNewSession(for tab: MeetTab) async {
        let workspace: AutoRecordWorkspace
        do {
            workspace = try await provider.quickRecord(overrides: Self.overrides(for: tab))
        } catch {
            logger.error("auto-record start failed for meeting \(tab.code, privacy: .public): \(String(describing: error), privacy: .public)")
            return
        }
        guard case .recording = workspace.recordingButtonState else {
            logger.error("auto-record start failed for session \(workspace.sessionId, privacy: .public): state is not recording; leaving the draft for the user")
            return
        }
        let id = workspace.sessionId
        let deadline = clock.now.addingTimeInterval(Self.startBannerDuration)
        managed[id] = ManagedSession(
            sessionId: id, meetingCode: tab.code, phase: .recording, pausedByCoordinator: false,
            endTimer: nil, startBannerDeadline: deadline, startBannerTimer: nil
        )
        currentSessionId = id
        attach(workspace)
        scheduleStartBannerExpiry(id, deadline: deadline)
        logger.info("auto-started session \(id, privacy: .public): joined Google Meet \(tab.code, privacy: .public)")
    }

    static func overrides(for tab: MeetTab) -> DraftMetaOverrides {
        let title = tab.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let isPlaceholder = title.isEmpty
            || title.caseInsensitiveCompare(tab.code) == .orderedSame
            || title.caseInsensitiveCompare("Meet") == .orderedSame
        return DraftMetaOverrides(
            title: isPlaceholder ? nil : title,
            titleAutoNamedOnce: !isPlaceholder,
            autoRecord: AutoRecordMeta(source: .googleMeet, meetingCode: tab.code)
        )
    }

    // MARK: Leave

    private func handleLeft(code: String) async {
        guard let id = currentSessionId, let entry = managed[id], entry.meetingCode == code else {
            logger.info("meeting \(code, privacy: .public) left: no managed session, ignoring")
            return
        }
        guard entry.phase == .recording else { return }
        let workspace: AutoRecordWorkspace
        do {
            workspace = try await provider.workspace(for: id)
        } catch {
            logger.error("auto-pause failed for session \(id, privacy: .public): cannot open workspace: \(String(describing: error), privacy: .public)")
            removeEntry(id, reason: "workspace unavailable")
            return
        }
        guard managed[id] != nil else { return }
        guard case .recording = workspace.recordingButtonState else { return }
        attach(workspace)
        await perform(.pause, on: workspace) { await workspace.pauseRecording() }
        guard managed[id] != nil else { return }

        guard case .paused = workspace.recordingButtonState else {
            logger.error("auto-pause failed for session \(id, privacy: .public); the user can retry from the pause button")
            removeEntry(id, reason: "pause failed")
            return
        }
        managed[id]?.pausedByCoordinator = true
        let grace = graceSeconds()
        guard grace > 0 else {
            managed[id]?.phase = .pausedNoAutoEnd
            logger.info("auto-paused session \(id, privacy: .public): left meeting \(code, privacy: .public); auto end disabled")
            removeEntry(id, reason: "auto end disabled")
            return
        }
        let deadline = clock.now.addingTimeInterval(TimeInterval(grace))
        managed[id]?.phase = .pausedAwaitingEnd(deadline: deadline)
        workspace.showBanner(.autoRecordEndScheduled(deadline: deadline))
        managed[id]?.endTimer = Task { [self] in
            do { try await clock.sleep(until: deadline) } catch { return }
            await endTimerFired(id)
        }
        logger.info("auto-paused session \(id, privacy: .public): left meeting \(code, privacy: .public); ending in \(grace)s unless rejoined")
    }

    /// Section 3.2-3.
    private func endTimerFired(_ id: String) async {
        guard var entry = managed[id], case .pausedAwaitingEnd = entry.phase, entry.pausedByCoordinator else { return }
        // Detach the timer first: removing the entry cancels it, and this task is that timer.
        entry.endTimer = nil
        managed[id] = entry
        removeEntry(id, reason: "grace period expired")

        let workspace: AutoRecordWorkspace
        do {
            workspace = try await provider.workspace(for: id)
        } catch {
            logger.error("auto-end failed for session \(id, privacy: .public): cannot open workspace: \(String(describing: error), privacy: .public)")
            return
        }
        switch workspace.recordingButtonState {
        case .paused, .pausedDisabledOtherRecording: break
        default:
            logger.info("auto-end skipped for session \(id, privacy: .public): state changed")
            return
        }
        if workspace.hasConfirmedTranscript {
            await workspace.endMeeting()
            if case .ended = workspace.recordingButtonState {
                logger.info("auto-ended session \(id, privacy: .public): grace period expired after leaving the meeting")
            } else {
                logger.error("auto-end failed for session \(id, privacy: .public): state is not ended")
            }
        } else {
            logger.info("auto-discarding session \(id, privacy: .public): grace period expired and nothing was transcribed")
            await workspace.discardAutoRecordedSession()
        }
    }

    // MARK: Banner buttons

    private func handleBannerAction(sessionId id: String, action: BannerActionID) {
        guard managed[id] != nil else { return }
        switch action {
        case .keepMeetingOpen:
            logger.info("auto-end cancelled for session \(id, privacy: .public) by the user")
            removeEntry(id, reason: "user kept the meeting open")
        case .cancelAutoRecord:
            Task { [self] in await discard(sessionId: id) }
        }
    }

    /// The `取り消す` button (section 3.5).
    func discard(sessionId id: String) async {
        guard managed[id] != nil, let workspace = liveWorkspaces[id]?.value else { return }
        // An automatic pause may still be in flight; discarding is a no-op until it settles.
        if Self.isTransitional(workspace.recordingButtonState) {
            for await state in workspace.recordingButtonStatePublisher.values where !Self.isTransitional(state) {
                break
            }
        }
        guard managed[id] != nil else { return }
        logger.info("discarding auto-recorded session \(id, privacy: .public): cancelled by the user")
        var discarded = false
        await perform(.discard, on: workspace) { discarded = await workspace.discardAutoRecordedSession() }
        if discarded {
            removeEntry(id, reason: "discarded")
        } else {
            logger.info("discard of session \(id, privacy: .public) was a no-op; keeping it managed")
        }
    }

    private static func isTransitional(_ state: RecordingButtonState) -> Bool {
        switch state {
        case .starting, .pausing, .resuming: return true
        default: return false
        }
    }

    // MARK: Entry bookkeeping

    private func attach(_ workspace: AutoRecordWorkspace) {
        let id = workspace.sessionId
        guard let entry = managed[id] else { return }
        liveWorkspaces[id] = WeakWorkspace(value: workspace)
        lastState[id] = workspace.recordingButtonState
        subscriptions[id] = workspace.recordingButtonStatePublisher
            .dropFirst()
            .sink { [weak self] state in
                MainActor.assumeIsolated { self?.stateChanged(sessionId: id, to: state) }
            }
        workspace.onBannerAction = { [weak self] _, action in self?.handleBannerAction(sessionId: id, action: action) }
        if let deadline = entry.startBannerDeadline, clock.now < deadline {
            workspace.showBanner(.autoRecordStarted(sessionId: id))
        }
        if case .pausedAwaitingEnd(let deadline) = entry.phase {
            workspace.showBanner(.autoRecordEndScheduled(deadline: deadline))
        }
    }

    /// Section 3.0.3: a transition nobody on our side asked for is the user's.
    private func stateChanged(sessionId id: String, to new: RecordingButtonState) {
        let previous = lastState[id]
        lastState[id] = new
        guard operationInFlight[id] == nil, managed[id] != nil, let previous else { return }

        let wasRecordingOrPaused: Bool
        switch previous {
        case .recording, .paused, .pausedDisabledOtherRecording: wasRecordingOrPaused = true
        default: wasRecordingOrPaused = false
        }
        let reason: String?
        switch (previous, new) {
        case (.recording, .pausing): reason = "user paused"
        case (.paused, .resuming), (.pausedDisabledOtherRecording, .resuming): reason = "user resumed"
        case (_, .ending) where wasRecordingOrPaused: reason = "user ended the meeting"
        default: reason = nil
        }
        if let reason { removeEntry(id, reason: reason) }
    }

    private func perform(_ operation: Operation, on workspace: AutoRecordWorkspace, _ body: () async -> Void) async {
        let id = workspace.sessionId
        operationInFlight[id] = operation
        await body()
        operationInFlight[id] = nil
        if managed[id] != nil { lastState[id] = workspace.recordingButtonState }
    }

    private func scheduleStartBannerExpiry(_ id: String, deadline: Date) {
        managed[id]?.startBannerTimer = Task { [self] in
            do { try await clock.sleep(until: deadline) } catch { return }
            guard var entry = managed[id] else { return }
            entry.startBannerDeadline = nil
            entry.startBannerTimer = nil
            managed[id] = entry
            // A closed window took its banners with it; nothing to remove then.
            liveWorkspaces[id]?.value?.removeBanners(withId: WorkspaceBanner.autoRecordStarted(sessionId: id).id)
        }
    }

    private func removeEntry(_ id: String, reason: String) {
        guard let entry = managed.removeValue(forKey: id) else { return }
        entry.endTimer?.cancel()
        entry.startBannerTimer?.cancel()
        if let workspace = liveWorkspaces[id]?.value {
            workspace.removeBanners(withId: WorkspaceBanner.autoRecordStarted(sessionId: id).id)
            workspace.removeBanners(withId: WorkspaceBanner.autoRecordEndScheduled(deadline: .distantPast).id)
            workspace.onBannerAction = nil
        }
        subscriptions.removeValue(forKey: id)
        liveWorkspaces.removeValue(forKey: id)
        lastState.removeValue(forKey: id)
        operationInFlight.removeValue(forKey: id)
        if currentSessionId == id { currentSessionId = nil }
        logger.info("session \(id, privacy: .public) is no longer auto-managed: \(reason, privacy: .public)")
    }
}
