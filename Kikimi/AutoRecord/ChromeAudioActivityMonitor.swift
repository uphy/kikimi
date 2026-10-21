import CoreAudio
import Foundation

/// One OR-ed snapshot of every Chrome audio process. See `docs/design/50-meet-auto-record.md` section 2.1.
struct ChromeAudioActivity: Equatable, Sendable {
    var input: Bool
    var output: Bool

    static let silent = ChromeAudioActivity(input: false, output: false)

    var isActive: Bool { input || output }
}

/// Source of Chrome audio snapshots, so `MeetPresenceMonitor` can be driven by a fake in tests.
protocol ChromeAudioActivitySource: AnyObject {
    /// Delivers one snapshot immediately and then periodically, on the main queue.
    func start(handler: @escaping (ChromeAudioActivity) -> Void)
    func stop()
}

/// Reads the per-process `IsRunningInput` / `IsRunningOutput` flags of every process whose bundle id
/// starts with `com.google.Chrome` (measured: the flag lands on `com.google.Chrome.helper`, not the
/// main process). Polled once per second while running; does nothing while stopped.
final class ChromeAudioActivityMonitor: ChromeAudioActivitySource {
    static let bundleIdPrefix = "com.google.Chrome"

    private let interval: TimeInterval
    private var timer: DispatchSourceTimer?

    init(interval: TimeInterval = 1.0) {
        self.interval = interval
    }

    deinit { stop() }

    /// Starts the timer; `handler` runs on the main queue once immediately and then every `interval`.
    func start(handler: @escaping (ChromeAudioActivity) -> Void) {
        stop()
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now(), repeating: interval)
        source.setEventHandler { handler(Self.sample()) }
        timer = source
        source.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    static func isChromeBundleId(_ bundleId: String?) -> Bool {
        bundleId?.hasPrefix(bundleIdPrefix) == true
    }

    /// One synchronous read of the current state.
    static func sample() -> ChromeAudioActivity {
        var activity = ChromeAudioActivity.silent
        for objectID in AudioInputEnumerator.readProcessObjectIDs() {
            guard isChromeBundleId(AudioInputEnumerator.readProcessBundleID(objectID: objectID)) else { continue }
            if AudioInputEnumerator.readProcessIsRunningInput(objectID: objectID) { activity.input = true }
            if AudioInputEnumerator.readProcessState(objectID: objectID, selector: kAudioProcessPropertyIsRunningOutput) {
                activity.output = true
            }
        }
        return activity
    }
}
