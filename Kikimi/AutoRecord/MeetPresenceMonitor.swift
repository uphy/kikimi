import Foundation
import OSLog

/// I/O side of `MeetPresenceDetector`: samples Chrome audio once per second, runs tab queries (one at a
/// time) and forwards `joined` / `left` events. See `docs/design/50-meet-auto-record.md` section 2.3.
@MainActor
final class MeetPresenceMonitor {
    private let trace = AutoRecordTrace(category: "MeetPresenceMonitor")
    private let audioMonitor: ChromeAudioActivitySource
    private let inspector: ChromeTabInspecting
    private let now: () -> Date

    private var detector: MeetPresenceDetector
    private var isRunning = false
    /// True from query launch until the `NSAppleScript` call actually returns.
    private var isQueryRunning = false
    private var pendingRequest: MeetPresenceDetector.QueryRequest?
    private var lastPermitted: Bool?
    /// Bumped on start/stop so results of queries launched before a restart are never fed to the new detector
    /// (the fresh detector restarts its generation counter at 0).
    private var epoch = 0

    /// Called on the main actor for each detected event.
    var onEvent: ((MeetPresenceDetector.Event) -> Void)?

    init(
        audioMonitor: ChromeAudioActivitySource = ChromeAudioActivityMonitor(),
        inspector: ChromeTabInspecting = ChromeTabInspector(),
        detector: MeetPresenceDetector = MeetPresenceDetector(),
        now: @escaping () -> Date = Date.init
    ) {
        self.audioMonitor = audioMonitor
        self.inspector = inspector
        self.detector = detector
        self.now = now
    }

    var isMonitoring: Bool { isRunning }

    /// Starts polling. The first snapshot is compared against "no previous value", so joining before
    /// launch is detected as a rise.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        epoch += 1
        detector = MeetPresenceDetector(
            retryDelays: detector.retryDelays, leaveDebounce: detector.leaveDebounce,
            switchCheckInterval: detector.switchCheckInterval
        )
        lastPermitted = nil
        pendingRequest = nil
        audioMonitor.start { [weak self] audio in
            MainActor.assumeIsolated { self?.handle(audio) }
        }
        trace.info("meet presence monitoring started")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        epoch += 1
        audioMonitor.stop()
        pendingRequest = nil
        trace.info("meet presence monitoring stopped")
    }

    private func handle(_ audio: ChromeAudioActivity) {
        guard isRunning else { return }
        // Cheap, non-prompting permission check; only needed while the detector is waiting for it
        // (design 50 section 2.3), so it is not run every second on the main thread otherwise.
        if lastPermitted != true, detector.isAwaitingPermission {
            if let permitted = inspector.automationPermitted() { lastPermitted = permitted }
        }
        let output = detector.handleSnapshot(audio, automationPermitted: lastPermitted ?? false, now: now())
        process(output)
    }

    private func process(_ output: MeetPresenceDetector.Output) {
        for event in output.events {
            // Codes only: a `joined` tab also carries the meeting title.
            switch event {
            case let .joined(tab): trace.info("meet presence event: joined \(tab.code)")
            case let .left(code): trace.info("meet presence event: left \(code)")
            }
            onEvent?(event)
        }
        if let request = output.query { launch(request) }
    }

    private func launch(_ request: MeetPresenceDetector.QueryRequest) {
        // Never stack queries behind a blocked one; run the latest request when it returns.
        guard !isQueryRunning else {
            pendingRequest = request
            return
        }
        isQueryRunning = true
        trace.info("tab query \(request.generation) started")
        let inspector = inspector
        let launchEpoch = epoch
        Task { [weak self] in
            let result = await inspector.inspect(mode: .monitoring)
            self?.queryFinished(result, request: request, epoch: launchEpoch)
        }
    }

    private func queryFinished(_ result: ChromeTabInspectionResult, request: MeetPresenceDetector.QueryRequest, epoch resultEpoch: Int) {
        isQueryRunning = false
        trace.info("tab query \(request.generation) finished: \(Self.summary(of: result))")
        switch result {
        case .tabs: lastPermitted = true
        // Forget a stale "permitted" so the non-prompting check runs again and can notice a re-grant.
        case .failed(.notAuthorized), .failed(.notDetermined): lastPermitted = false
        default: break
        }
        if isRunning, resultEpoch == epoch {
            // Stale generations are dropped by the detector.
            process(detector.handleQueryResult(result, generation: request.generation, now: now()))
        }
        if let pending = pendingRequest {
            pendingRequest = nil
            // Any request still current is relaunched: a check during `Checking` and an in-meeting switch
            // check alike (dropping the latter would leave the detector waiting for its result forever).
            if isRunning, detector.currentGeneration == pending.generation {
                launch(pending)
            }
        }
    }

    /// Log-safe summary: counts only, no URLs, titles or meeting codes.
    private static func summary(of result: ChromeTabInspectionResult) -> String {
        switch result {
        case let .tabs(tabs):
            "\(tabs.count) meet tab(s), frontmost meet tab: \(tabs.contains(where: \.isFrontmost))"
        case .chromeNotRunning:
            "chrome not running"
        case let .failed(failure):
            "failed (\(failure))"
        }
    }
}
