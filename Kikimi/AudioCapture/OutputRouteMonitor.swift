import CoreAudio
import Foundation
import OSLog

// MARK: - OutputRouteClassification

/// Pure classification of a CoreAudio device's `kAudioDevicePropertyTransportType`, used by
/// `OutputRouteMonitor` to decide whether the current default output device is likely to leak audio
/// into the mic (`docs/design/24-system-audio-leak-mitigation.md` section 5.1).
enum OutputRouteClassification: Equatable, Sendable {
    /// The built-in speaker (`kAudioDeviceTransportTypeBuiltIn`) -- acoustic leakage into the mic is
    /// likely.
    case builtInSpeaker
    /// Any other transport type (Bluetooth/USB/HDMI/AirPlay/etc). Deliberately lumps headphones in
    /// with everything else that isn't the built-in speaker -- a false negative (e.g. a Bluetooth
    /// speaker misclassified as safe) is accepted in exchange for never nagging headphone users
    /// (design section 5.1's "既知の限界").
    case other

    /// `kAudioDeviceTransportTypeBuiltIn` classifies as `.builtInSpeaker`; every other transport type
    /// value classifies as `.other` (design section 5.1's "単純な二値判定").
    static func classify(transportType: UInt32) -> OutputRouteClassification {
        transportType == kAudioDeviceTransportTypeBuiltIn ? .builtInSpeaker : .other
    }
}

// MARK: - OutputRouteMonitor

/// Polls the system's default output device's transport type at a fixed interval and reports
/// `OutputRouteClassification` changes (`docs/design/24-system-audio-leak-mitigation.md` section 5.1).
///
/// Deliberately polling-based rather than subscribing to `AudioObjectAddPropertyListener` on
/// `kAudioHardwarePropertyDefaultOutputDevice` -- see the design doc's section 5.1 for the full
/// rationale, which mirrors `SystemAudioSource.startStallTimer()`'s own choice of a
/// `DispatchSource.makeTimerSource` timeout check over a CoreAudio property listener.
///
/// Not an actor / not `Sendable`-isolated by the type system: like `SystemAudioSource`, all mutable
/// state is confined to `queue`, and `onChange` is always invoked on that same queue.
final class OutputRouteMonitor {
    private let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "OutputRouteMonitor")

    /// Serial queue both the poll timer and every CoreAudio call run on. `onChange` fires on this
    /// queue too, mirroring `AudioCapture.eventQueue`'s "callers hop to their own queue if needed"
    /// contract.
    private let queue: DispatchQueue
    private let pollInterval: TimeInterval

    private var timer: DispatchSourceTimer?
    private var lastClassification: OutputRouteClassification?
    private var isRunning = false

    /// Invoked on `queue` only when the classification actually changes from its previous value
    /// (design section 5.1: "判定結果が変わったときだけ delegate/closure で通知する"). Never invoked
    /// with the same value twice in a row, including across the very first evaluation (which always
    /// counts as a change from "no prior classification").
    var onChange: (@Sendable (OutputRouteClassification) -> Void)?

    /// - Parameters:
    ///   - pollInterval: Seconds between re-evaluations (design section 5.1's default of 10s).
    ///   - queue: Injectable for testing; defaults to a dedicated serial queue.
    init(
        pollInterval: TimeInterval = 10.0,
        queue: DispatchQueue = DispatchQueue(label: "io.github.uphy.Kikimi.OutputRouteMonitor")
    ) {
        self.pollInterval = pollInterval
        self.queue = queue
    }

    deinit {
        stop()
    }

    /// Evaluates the current default output device once immediately, then starts the poll timer.
    /// Safe to call again after `stop()`; a no-op if already running.
    func start() {
        queue.async { [weak self] in
            self?.startOnQueue()
        }
    }

    /// Stops the poll timer. Does not reset `lastClassification` -- a subsequent `start()` still only
    /// reports a change if the freshly-evaluated classification differs from what was last reported
    /// before `stop()` was called.
    func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
            self?.isRunning = false
        }
    }

    private func startOnQueue() {
        guard !isRunning else {
            return
        }
        isRunning = true

        evaluateOnQueue()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        timer.setEventHandler { [weak self] in
            self?.evaluateOnQueue()
        }
        timer.resume()
        self.timer = timer
    }

    private func evaluateOnQueue() {
        guard isRunning else {
            return
        }
        guard let classification = Self.resolveCurrentClassification(logger: logger) else {
            return
        }
        guard classification != lastClassification else {
            return
        }
        lastClassification = classification
        onChange?(classification)
    }

    /// Reads the default output device and its transport type, returning `nil` (and logging a
    /// `.warning`) if either CoreAudio call fails (design section 5.1/7 failure mode #4: "検知を継続し
    /// クラッシュさせない。判定は nil 扱い（banner は出さない）").
    private static func resolveCurrentClassification(logger: Logger) -> OutputRouteClassification? {
        guard let deviceID = resolveDefaultOutputDeviceID() else {
            logger.warning("OutputRouteMonitor failed to resolve the default output device; skipping this evaluation")
            return nil
        }
        guard let transportType = readTransportType(deviceID: deviceID) else {
            logger.warning("OutputRouteMonitor failed to read the transport type for device \(deviceID, privacy: .public); skipping this evaluation")
            return nil
        }
        return OutputRouteClassification.classify(transportType: transportType)
    }

    private static func resolveDefaultOutputDeviceID() -> AudioObjectID? {
        var deviceID = kAudioObjectUnknown
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            return nil
        }
        return deviceID
    }

    private static func readTransportType(deviceID: AudioObjectID) -> UInt32? {
        var transportType = UInt32(0)
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &transportType)
        guard status == noErr else {
            return nil
        }
        return transportType
    }
}
