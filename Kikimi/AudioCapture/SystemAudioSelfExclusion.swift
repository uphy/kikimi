import AVFoundation
import CoreAudio
import Foundation

// MARK: - Self-process exclusion (docs/design/01-audio-capture.md section 4, failure mode #11)
//
// Split out of `SystemAudioSource.swift` purely to stay under swiftlint's `file_length` budget;
// logically part of the same type. `SystemAudioSource.resolveExcludedProcesses()` (instance
// method, in `SystemAudioSource.swift`) is the entry point and owns the full rationale doc
// comment; this file holds the retry/priming policy and the raw CoreAudio calls it composes.
//
// Background: `kAudioHardwarePropertyTranslatePIDToProcessObject` only resolves a pid once
// coreaudiod has observed that process perform actual audio I/O. A mic-enabled recording gets
// this for free (`MicrophoneSource.start` runs before `SystemAudioSource.start` in
// `AudioCapture.start()`), but a system-audio-only recording may not have touched CoreAudio at
// all yet, so the very first resolution attempt can fail every time. Left unhandled, that meant
// Kikimi's own process tap-exclusion silently degraded to "exclude nobody" -- and once the user
// played back a segment (`Kikimi/Playback/SegmentAudioPlayer.swift`), that playback audio would
// be captured by the system-audio tap and corrupt the transcript.
/// Keeps the priming `AVAudioEngine` (and therefore Kikimi's CoreAudio HAL client registration)
/// alive for as long as the token itself is retained; releasing the token stops the engine. See
/// `SystemAudioSource.primeSelfHALRegistration()` for why the engine must keep running past the
/// resolution call.
private final class SelfHALRegistrationToken {
    private let engine: AVAudioEngine

    init(engine: AVAudioEngine) {
        self.engine = engine
    }

    deinit {
        engine.stop()
    }
}

extension SystemAudioSource {
    /// Number of `resolveSelfProcessObjectID()` retries attempted after
    /// `primeSelfHALRegistration()` runs, before giving up. Kept small: each retry only matters if
    /// coreaudiod's process list is lagging a few milliseconds behind the I/O stream that
    /// `primeSelfHALRegistration()` itself just started and stopped -- not a genuinely
    /// unresolvable state that more retries would fix.
    static let selfResolutionRetryCount = 3
    static let selfResolutionRetryDelay: TimeInterval = 0.05

    /// Pure retry/give-up policy factored out into injectable closures so it can be unit tested
    /// without touching real CoreAudio/AVAudioEngine state: `resolveSelf`/`primeSelfRegistration`/
    /// `sleep` are fakes in tests, and `onGiveUp` lets tests observe the give-up branch without
    /// depending on `Logger` output. Tries `resolveSelf()` once; if that fails, calls
    /// `primeSelfRegistration()` once and retries `resolveSelf()` up to `retryCount` times
    /// (sleeping `selfResolutionRetryDelay` between attempts), and finally calls `onGiveUp()` and
    /// returns `additionalExcludedProcesses` unchanged if every attempt failed.
    ///
    /// The returned `primingToken` is whatever `primeSelfRegistration()` produced (`nil` when
    /// priming was never needed or resolution ultimately failed). In production it keeps the
    /// priming HAL client alive (see `primeSelfHALRegistration()`); the caller must hold it until
    /// the exclude list has actually been consumed by `AudioHardwareCreateProcessTap`, because
    /// coreaudiod may drop a process object again once its last audio I/O stops.
    static func resolveExcludedProcesses(
        additionalExcludedProcesses: [AudioObjectID],
        resolveSelf: () -> AudioObjectID?,
        primeSelfRegistration: () -> Any?,
        retryCount: Int = selfResolutionRetryCount,
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        onGiveUp: () -> Void
    ) -> (excluded: [AudioObjectID], primingToken: Any?) {
        if let selfObjectID = resolveSelf() {
            return (additionalExcludedProcesses + [selfObjectID], nil)
        }

        let primingToken = primeSelfRegistration()
        for attempt in 0..<retryCount {
            if let selfObjectID = resolveSelf() {
                return (additionalExcludedProcesses + [selfObjectID], primingToken)
            }
            if attempt < retryCount - 1 {
                sleep(selfResolutionRetryDelay)
            }
        }

        onGiveUp()
        // Resolution failed, so there is no exclude entry for the token to keep valid -- drop it
        // (releasing it stops the priming engine) rather than making the caller hold a useless
        // running output stream.
        return (additionalExcludedProcesses, nil)
    }

    /// Forces Kikimi to become a registered CoreAudio HAL client by starting a silent
    /// `AVAudioEngine` output stream against the default output device. Only the lazily-created
    /// mixer -> output connection exists in the graph and nothing renders into it, so no audible
    /// output is produced -- this exists purely to make `resolveSelfProcessObjectID()`
    /// resolvable, mirroring what `MicrophoneSource.start` already causes as a side effect when
    /// the microphone is enabled.
    ///
    /// Returns a token that keeps the engine *running* until released: coreaudiod may drop the
    /// process object again once the process's last audio I/O stops, so a start/stop pair here
    /// could invalidate the just-resolved `AudioObjectID` before the tap is even created. The
    /// caller (`SystemAudioSource.start()`) holds the token until the tap's own aggregate-device
    /// IOProc is running, at which point Kikimi is a registered HAL client in its own right.
    ///
    /// Best-effort: a `nil` return (e.g. no output device available) just means the retry loop
    /// in `resolveExcludedProcesses(...)` above falls through to its give-up branch, which is
    /// already a safe (if imperfect) fallback.
    static func primeSelfHALRegistration() -> Any? {
        let engine = AVAudioEngine()
        // Touching `mainMixerNode` lazily creates the mixer and implicitly connects it to
        // `outputNode`. Without at least this connection in the graph, `AVAudioEngine.start()`
        // throws before ever opening an output stream and no HAL client registration happens --
        // which would make this whole priming step a silent no-op.
        _ = engine.mainMixerNode
        do {
            try engine.start()
            return SelfHALRegistrationToken(engine: engine)
        } catch {
            // Nothing actionable here: the retry loop above still gets a chance in case
            // coreaudiod already knew about this process through some other means.
            return nil
        }
    }

    static func resolveSelfProcessObjectID() -> AudioObjectID? {
        var pid = ProcessInfo.processInfo.processIdentifier
        var objectID = kAudioObjectUnknown
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &pid,
            &dataSize,
            &objectID
        )
        guard status == noErr, objectID != kAudioObjectUnknown else {
            return nil
        }
        return objectID
    }
}
