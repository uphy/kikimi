import AVFoundation
import Foundation

// MARK: - AudioSourceKind

/// Identifies which independent audio stream a buffer/event originates from.
///
/// Kikimi captures microphone and system audio as two independent streams
/// (see `docs/design/01-audio-capture.md` section 3); this type distinguishes them
/// wherever a buffer, error, or level needs to be attributed to one of the two.
///
/// `CaseIterable` (`docs/design/summary-quality-topics-and-final-pass.md` §6.2): lets
/// `SummaryPatchApplier`'s reserved-participant-name filter derive its channel-label set
/// (`{"mic", "system"}`) from this type directly, instead of hand-duplicating the raw value list.
enum AudioSourceKind: String, Codable, Sendable, CaseIterable {
    case mic
    case system
}

// MARK: - AudioCaptureConfig

/// Tunable parameters for `AudioCapture`. See `docs/design/01-audio-capture.md` section 5/11.
struct AudioCaptureConfig: Equatable, Sendable {
    /// Target sample rate (Hz) for the downstream working format and WAV output. Kikimi standardizes on 16kHz mono.
    var sampleRate: Double = 16_000

    /// Target channel count for the downstream working format and WAV output.
    var channels: AVAudioChannelCount = 1

    /// Frame count requested when installing the microphone tap (`AVAudioEngine.inputNode.installTap`).
    var micTapBufferSize: AVAudioFrameCount = 1024

    /// Interval at which `WavFileWriter` rewrites the RIFF/data chunk sizes in the WAV header.
    /// Trades off crash-time playability against disk I/O frequency (see section 8).
    var headerFlushInterval: TimeInterval = 5.0
}

// MARK: - AudioCaptureState

/// Lifecycle state of an `AudioCapture` instance. See section 6 for the full transition diagram.
enum AudioCaptureState: Equatable, Sendable {
    case idle
    case starting
    case running(activeSources: Set<AudioSourceKind>)
    case stopping
    case stopped
}

// MARK: - AudioCaptureError

/// Failure modes surfaced by `AudioCapture`, either by throwing from `start()` or via
/// `AudioCaptureDelegate.audioCapture(_:didDegrade:error:)`. See section 9 for the full failure-mode table.
enum AudioCaptureError: LocalizedError, Equatable, Sendable {
    // Thrown from start() — recording is not started; the caller stays in Draft.
    case alreadyRunning
    case sessionDirectoryUnavailable(String)
    case microphonePermissionDenied
    case microphonePermissionRestricted
    case microphoneEngineFailed(String)
    /// Both microphone and system audio are unavailable (Recording cannot be started).
    case allSourcesUnavailable
    /// System audio is the only enabled source (`AudioInputSelection.mic.enabled == false`) and it
    /// failed to start. Unlike the mic-enabled case (where a system audio failure degrades to
    /// mic-only), there is no fallback source left, so this is fatal (`docs/design/10-audio-input-selection.md`
    /// section 5.2, row 3).
    case systemAudioStartFailed(message: String)

    // Degradation reported while recording continues (via delegate). Recording is not stopped.
    case systemAudioUnavailable(message: String)
    case fileWriteFailed(source: AudioSourceKind, message: String)

    // NOTE: a `bufferConversionDropped(source:)` case previously existed here for section 9's
    // failure mode #6 (`AVAudioConverter.convert` dropping a single buffer), but nothing ever
    // constructed it: `SystemAudioSource`/`MicrophoneSource` only have an `onDegraded`-style hook
    // for a source going fully unavailable, not a per-buffer conversion drop, and wiring one up
    // for a single already-logged `.warning` would be over-engineering for a case with no current
    // caller. Per-buffer drops are still logged via `Logger` at the drop site in both sources.
    // Revisit (re-add this case and a real notification path) if frequent drops turn out to need
    // UI-visible surfacing (see design doc section 9, failure mode #6).

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "Audio capture is already running."
        case .sessionDirectoryUnavailable(let message):
            return "The session directory is unavailable: \(message)"
        case .microphonePermissionDenied:
            return "Microphone access was denied."
        case .microphonePermissionRestricted:
            return "Microphone access is restricted."
        case .microphoneEngineFailed(let message):
            return "Failed to start the microphone audio engine: \(message)"
        case .allSourcesUnavailable:
            return "Neither microphone nor system audio is available."
        case .systemAudioStartFailed(let message):
            return "Failed to start system audio capture: \(message)"
        case .systemAudioUnavailable(let message):
            return "System audio is unavailable: \(message)"
        case .fileWriteFailed(let source, let message):
            return "Failed to write the \(source.rawValue) audio file: \(message)"
        }
    }
}

// MARK: - AudioCaptureDelegate

/// Receives capture events from `AudioCapture`.
///
/// All four methods are called on `AudioCapture`'s internal serial `eventQueue`
/// (see `docs/design/01-audio-capture.md` section 5.1), **never on the main thread** and never
/// concurrently with each other (events from both sources are serialized onto this single queue).
/// Conforming types that need to update UI state must explicitly hop to `DispatchQueue.main` /
/// `@MainActor` themselves; `AudioCapture` does not guarantee main-thread delivery. Implementations
/// should also avoid doing heavy work directly on these callbacks and instead hand off quickly
/// (e.g. to a ring buffer), since this queue is shared by all delegate events.
protocol AudioCaptureDelegate: AnyObject {
    /// A converted PCM buffer is available. `elapsed` is the time interval, in seconds, since
    /// the moment `start()` succeeded.
    ///
    /// Called on `eventQueue`; not the main thread.
    func audioCapture(_ capture: AudioCapture, didCapture buffer: AVAudioPCMBuffer, source: AudioSourceKind, elapsed: TimeInterval)

    /// Recording continues, but the given source has degraded (e.g. for a UI banner).
    ///
    /// Called on `eventQueue`; not the main thread.
    func audioCapture(_ capture: AudioCapture, didDegrade source: AudioSourceKind, error: AudioCaptureError)

    /// Reports a level-meter value for the given source.
    ///
    /// Called on `eventQueue`; not the main thread.
    func audioCapture(_ capture: AudioCapture, didUpdateLevel level: Double, source: AudioSourceKind)

    /// Recording has fully stopped.
    ///
    /// Called on `eventQueue`; not the main thread.
    func audioCaptureDidStop(_ capture: AudioCapture)
}

// MARK: - AudioSourceCapturing

/// Internal abstraction over a single audio source (microphone, system audio, or a test input),
/// allowing `AudioCapture` to substitute implementations for testing. Mirrors Chirami's
/// `MicrophoneCapturing` / `SystemAudioCapturing` DI pattern.
protocol AudioSourceCapturing: AnyObject {
    /// Starts capturing and invokes `bufferHandler` for each converted buffer, paired with the
    /// host time captured before conversion (see section 7.1). Throws if the source cannot be started.
    func start(bufferHandler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) throws

    /// Stops capturing. Safe to call even if not currently running.
    func stop()
}
