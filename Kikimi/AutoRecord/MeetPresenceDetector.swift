import Foundation

/// Pure state machine deciding when the user joined / left a Google Meet call.
/// See `docs/design/50-meet-auto-record.md` section 2.3. No I/O and no clock: audio snapshots, tab
/// query results and the time are all passed in, so the whole thing is testable with injected dates.
struct MeetPresenceDetector {
    enum Event: Equatable, Sendable {
        case joined(MeetTab)
        case left(code: String)
    }

    /// "Start a tab query now". The result must be returned with the same `generation`.
    struct QueryRequest: Equatable, Sendable {
        let generation: Int
    }

    struct Output: Equatable, Sendable {
        var events: [Event] = []
        var query: QueryRequest?
    }

    private enum ExhaustedReason: Equatable {
        case permission
        case noMeet
    }

    private enum State: Equatable {
        case idle
        case checking(retriesDone: Int)
        case retryWait(due: Date, retriesDone: Int)
        case exhausted(ExhaustedReason)
        case inMeeting(tab: MeetTab, sawInput: Bool)
        case leavePending(tab: MeetTab, since: Date, sawInput: Bool)
    }

    /// Delays from the audio rise at which retries happen (3 retries at most).
    let retryDelays: [TimeInterval]
    /// How long the input must stay off before `left` is emitted.
    let leaveDebounce: TimeInterval

    private var state: State = .idle
    private var generation = 0
    private var lastAudio: ChromeAudioActivity?
    private var riseAt = Date.distantPast
    private var permissionRetryUsed = false
    private var lastLeftCode: String?

    init(retryDelays: [TimeInterval] = [5, 15, 30], leaveDebounce: TimeInterval = 3) {
        self.retryDelays = retryDelays
        self.leaveDebounce = leaveDebounce
    }

    var isChecking: Bool {
        if case .checking = state { return true }
        return false
    }

    var currentGeneration: Int { generation }

    /// True while a missing Automation permission is the only thing blocking detection, i.e. while
    /// `handleSnapshot`'s `automationPermitted` argument is actually consulted.
    var isAwaitingPermission: Bool {
        if case .exhausted(.permission) = state { return true }
        return false
    }

    var isInMeeting: Bool {
        switch state {
        case .inMeeting, .leavePending: true
        default: false
        }
    }

    /// Feed one audio snapshot (called about once per second).
    /// - Parameter automationPermitted: latest non-prompting Automation permission check; only
    ///   consulted while waiting for the user to grant it.
    mutating func handleSnapshot(_ audio: ChromeAudioActivity, automationPermitted: Bool = false, now: Date) -> Output {
        let previous = lastAudio ?? .silent
        lastAudio = audio
        let rose = (audio.input && !previous.input) || (audio.output && !previous.output)
        var output = Output()

        switch state {
        case .idle:
            if rose {
                riseAt = now
                permissionRetryUsed = false
                startCheck(retriesDone: 0, output: &output)
            }

        case .checking:
            // Keep the latest audio state (stored above); drop out if everything went quiet.
            if !audio.isActive { resetToIdle() }

        case let .retryWait(due, retriesDone):
            if !audio.isActive {
                resetToIdle()
            } else if now >= due {
                startCheck(retriesDone: retriesDone + 1, output: &output)
            }

        case let .exhausted(reason):
            if !audio.isActive {
                resetToIdle()
            } else if reason == .noMeet, rose {
                // A new rise while other Chrome audio keeps playing (Meet joined during YouTube: `in`
                // rises) is a fresh attempt with its own retry schedule (section 2.3).
                riseAt = now
                startCheck(retriesDone: 0, output: &output)
            } else if reason == .permission, automationPermitted, !permissionRetryUsed {
                permissionRetryUsed = true
                startCheck(retriesDone: retryDelays.count, output: &output)
            }

        case let .inMeeting(tab, sawInput):
            let saw = sawInput || audio.input
            if Self.hasLeft(audio, sawInput: saw) {
                state = .leavePending(tab: tab, since: now, sawInput: saw)
            } else {
                state = .inMeeting(tab: tab, sawInput: saw)
            }

        case let .leavePending(tab, since, sawInput):
            let saw = sawInput || audio.input
            if !Self.hasLeft(audio, sawInput: saw) {
                state = .inMeeting(tab: tab, sawInput: saw)
            } else if now.timeIntervalSince(since) >= leaveDebounce {
                lastLeftCode = tab.code
                resetToIdle()
                output.events.append(.left(code: tab.code))
            }
        }
        return output
    }

    /// Feed the result of a tab query. Results of stale generations are ignored.
    mutating func handleQueryResult(_ result: ChromeTabInspectionResult, generation resultGeneration: Int, now: Date) -> Output {
        var output = Output()
        guard resultGeneration == generation, case let .checking(retriesDone) = state else { return output }

        switch result {
        case let .tabs(tabs):
            if let tab = chooseTab(tabs) {
                state = .inMeeting(tab: tab, sawInput: lastAudio?.input ?? false)
                output.events.append(.joined(tab))
                return output
            }
            scheduleRetry(retriesDone: retriesDone)
        case .chromeNotRunning:
            scheduleRetry(retriesDone: retriesDone)
        case let .failed(failure):
            switch failure {
            case .notAuthorized, .notDetermined:
                state = .exhausted(.permission)
            case .timeout, .other:
                scheduleRetry(retriesDone: retriesDone)
            }
        }
        return output
    }

    // MARK: - Helpers

    private mutating func startCheck(retriesDone: Int, output: inout Output) {
        generation += 1
        state = .checking(retriesDone: retriesDone)
        output.query = QueryRequest(generation: generation)
    }

    private mutating func scheduleRetry(retriesDone: Int) {
        if retriesDone < retryDelays.count {
            state = .retryWait(due: riseAt.addingTimeInterval(retryDelays[retriesDone]), retriesDone: retriesDone)
        } else {
            state = .exhausted(.noMeet)
        }
    }

    /// Bumps the generation so any in-flight result is discarded.
    private mutating func resetToIdle() {
        generation += 1
        state = .idle
    }

    /// Leave signal: input stopped, or (never saw input) output stopped.
    private static func hasLeft(_ audio: ChromeAudioActivity, sawInput: Bool) -> Bool {
        sawInput ? !audio.input : !audio.output
    }

    /// Active tab first, then a code other than the one just left (its "you left" screen lingers), then order.
    private func chooseTab(_ tabs: [MeetTab]) -> MeetTab? {
        let ranked = tabs.enumerated().sorted { lhs, rhs in
            let l = rank(lhs.element), r = rank(rhs.element)
            return l != r ? l < r : lhs.offset < rhs.offset
        }
        return ranked.first?.element
    }

    private func rank(_ tab: MeetTab) -> Int {
        (tab.isActive ? 0 : 2) + (tab.code == lastLeftCode ? 1 : 0)
    }
}
