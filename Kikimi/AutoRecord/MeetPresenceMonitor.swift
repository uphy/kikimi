import Foundation
import OSLog

/// I/O side of `MeetPresenceDetector`: samples Chrome audio once per second, runs tab queries (one at a
/// time) and forwards `joined` / `left` events. See `docs/design/50-meet-auto-record.md` section 2.3.
@MainActor
final class MeetPresenceMonitor {
    private let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "MeetPresenceMonitor")
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
        detector = MeetPresenceDetector(retryDelays: detector.retryDelays, leaveDebounce: detector.leaveDebounce)
        lastPermitted = nil
        pendingRequest = nil
        audioMonitor.start { [weak self] audio in
            MainActor.assumeIsolated { self?.handle(audio) }
        }
        logger.info("meet presence monitoring started")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        epoch += 1
        audioMonitor.stop()
        pendingRequest = nil
        logger.info("meet presence monitoring stopped")
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
            logger.info("meet presence event: \(String(describing: event))")
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
        let inspector = inspector
        let launchEpoch = epoch
        Task { [weak self] in
            let result = await inspector.inspect(mode: .monitoring)
            self?.queryFinished(result, request: request, epoch: launchEpoch)
        }
    }

    private func queryFinished(_ result: ChromeTabInspectionResult, request: MeetPresenceDetector.QueryRequest, epoch resultEpoch: Int) {
        isQueryRunning = false
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
            if isRunning, detector.isChecking, detector.currentGeneration == pending.generation {
                launch(pending)
            }
        }
    }
}
