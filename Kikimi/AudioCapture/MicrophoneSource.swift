import AVFoundation
import CoreAudio
import Foundation
import OSLog

/// Errors thrown by `MicrophoneSource.start(bufferHandler:)`.
///
/// Deliberately distinct from `AudioCaptureError`: `MicrophoneSource` only knows about the
/// microphone hardware/permission layer. The caller (`AudioCapture`) is responsible for mapping
/// these cases to `.microphonePermissionDenied` / `.microphonePermissionRestricted` /
/// `.microphoneEngineFailed` (`docs/design/01-audio-capture.md` section 5/9).
enum MicrophoneSourceError: LocalizedError, Equatable {
    case alreadyRunning
    case permissionDenied
    case permissionRestricted
    case unableToCreateConverter
    case engineFailed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "Microphone capture is already running."
        case .permissionDenied:
            return "Microphone access was denied."
        case .permissionRestricted:
            return "Microphone access is restricted."
        case .unableToCreateConverter:
            return "Failed to create an audio converter for the microphone input format."
        case .engineFailed(let underlying):
            return "Failed to start the microphone audio engine: \(underlying)"
        }
    }
}

extension AudioDeviceID {
    /// Sentinel returned by `kAudioHardwarePropertyTranslateUIDToDevice` (and other CoreAudio
    /// translation properties) when no device matches. CoreAudio defines this as
    /// `kAudioObjectUnknown`, which is untyped (`AudioObjectID` aka `UInt32`); this typed alias
    /// keeps call sites below readable.
    fileprivate static let unknown = AudioDeviceID(kAudioObjectUnknown)
}

/// Captures microphone audio via `AVAudioEngine.inputNode` and converts it to the shared
/// 16kHz mono Float32 std format used throughout `AudioCapture`.
///
/// `deviceUID == nil` targets the system default input device
/// (`docs/design/10-audio-input-selection.md` section 5.1); a non-`nil` UID is resolved to an
/// `AudioDeviceID` and routed onto `inputNode`'s audio unit. Modeled closely on Chirami's
/// `MicrophoneCapture.swift`, with two deliberate differences: the pre-conversion `AVAudioTime`
/// is preserved and forwarded (section 7.1) instead of being discarded, because Kikimi needs it
/// to compute `elapsed` for `transcript.jsonl`; and an invalid post-configuration input format
/// (e.g. zero input devices) is guarded against and surfaced as a thrown error instead of being
/// left to crash `installTap` with an Objective-C exception (section 5.1).
final class MicrophoneSource: AudioSourceCapturing {
    private let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "MicrophoneSource")

    private let engine: AVAudioEngine
    private let targetFormat: AVAudioFormat
    private let tapBufferSize: AVAudioFrameCount

    /// The CoreAudio device UID to route the microphone input to, or `nil` to follow the system
    /// default input device. Resolved to an `AudioDeviceID` in `configureInputDevice(on:)`
    /// (`docs/design/10-audio-input-selection.md` section 5.1).
    private let deviceUID: String?

    private var converter: AVAudioConverter?
    private var bufferHandler: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?
    private var isRunning = false

    /// Dedicated queue `requestAccessAndWait()` is dispatched onto (see `checkPermission()`), so the
    /// blocking `DispatchSemaphore.wait()` never executes directly on whatever thread called
    /// `start(bufferHandler:)`. Still a synchronous wait from the caller's perspective (`start`'s
    /// contract stays non-`async`), so callers must still not invoke `start(bufferHandler:)` from
    /// the main thread -- see the doc comment on `start(bufferHandler:)`.
    private static let permissionQueue = DispatchQueue(label: "io.github.uphy.Kikimi.MicrophoneSource.permission")

    /// - Parameters:
    ///   - deviceUID: CoreAudio device UID to capture from, or `nil` to follow the system default
    ///     input device (`docs/design/10-audio-input-selection.md` section 5.1).
    ///   - engine: Injectable for testing; defaults to a fresh `AVAudioEngine`.
    ///   - targetSampleRate: Output sample rate after conversion (Kikimi-wide default: 16kHz).
    ///   - targetChannels: Output channel count after conversion (Kikimi-wide default: mono).
    ///   - tapBufferSize: Frame count requested per `installTap` callback
    ///     (`AudioCaptureConfig.micTapBufferSize`, default 1024 frames, ~64ms at 16kHz).
    init(
        deviceUID: String? = nil,
        engine: AVAudioEngine = AVAudioEngine(),
        targetSampleRate: Double = 16_000,
        targetChannels: AVAudioChannelCount = 1,
        tapBufferSize: AVAudioFrameCount = 1024
    ) {
        self.deviceUID = deviceUID
        self.engine = engine
        self.tapBufferSize = tapBufferSize
        guard let targetFormat = AVAudioFormat(standardFormatWithSampleRate: targetSampleRate, channels: targetChannels) else {
            preconditionFailure("Failed to construct the standard mic output format (\(targetSampleRate)Hz, \(targetChannels)ch)")
        }
        self.targetFormat = targetFormat
    }

    /// Confirms microphone permission (requesting it if not yet determined), routes
    /// `AVAudioEngine.inputNode` to `deviceUID` (or the system default input if `nil`/unresolvable),
    /// installs a tap, converts each buffer to the target format, and starts the engine.
    ///
    /// Throws `MicrophoneSourceError.permissionDenied` / `.permissionRestricted` /
    /// `.engineFailed` / `.unableToCreateConverter` on failure; the caller (`AudioCapture`) maps
    /// these to the corresponding `AudioCaptureError` cases (section 9, failure modes #1/#2).
    ///
    /// - Important: Must not be called directly from the main thread/`@MainActor`. When permission
    ///   is not yet determined, this synchronously blocks the calling thread until the user responds
    ///   to the system TCC prompt (see `checkPermission()`/`requestAccessAndWait()`); blocking the
    ///   main thread would freeze the app's run loop for as long as that prompt is on screen. Callers
    ///   (e.g. `AudioCapture.start()`) must ensure they are already on a background thread/queue
    ///   before calling this.
    func start(bufferHandler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) throws {
        guard !isRunning else {
            throw MicrophoneSourceError.alreadyRunning
        }

        try Self.checkPermission()

        let inputNode = engine.inputNode
        // Must happen before reading `inputFormat(forBus:)` below: routing the input node to a
        // different device changes its format, so anything read/built beforehand (converter, tap)
        // would be built against the wrong device's format (`docs/design/10-audio-input-selection.md`
        // section 5.1's ordering constraint).
        configureInputDevice(deviceUID: deviceUID, on: inputNode)

        let inputFormat = inputNode.inputFormat(forBus: 0)
        // Guards against `installTap` crashing with an Objective-C exception (not a catchable
        // Swift error) when there are zero input devices available -- a state that can arise
        // between the ViewModel's pre-flight check and this `start()` call (e.g. during a
        // multi-minute model download), and that a resolved-but-now-empty device UID can also
        // land in after `configureInputDevice` falls back (section 5.1).
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw MicrophoneSourceError.engineFailed("input format is invalid (sampleRate=\(inputFormat.sampleRate), channelCount=\(inputFormat.channelCount)); no usable input device")
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw MicrophoneSourceError.unableToCreateConverter
        }

        self.converter = converter
        self.bufferHandler = bufferHandler

        inputNode.installTap(onBus: 0, bufferSize: tapBufferSize, format: inputFormat) { [weak self] buffer, when in
            self?.process(inputBuffer: buffer, when: when)
        }

        do {
            try engine.start()
            isRunning = true
        } catch {
            inputNode.removeTap(onBus: 0)
            cleanup()
            throw MicrophoneSourceError.engineFailed(error.localizedDescription)
        }
    }

    func stop() {
        guard isRunning else {
            cleanup()
            return
        }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        cleanup()
    }

    /// Routes `inputNode` to the device identified by `deviceUID`, if any.
    ///
    /// Falls back to the system default input device (i.e. leaves `inputNode` unconfigured) when
    /// `deviceUID` is `nil`, cannot be resolved to an `AudioDeviceID`, or the property write
    /// fails -- always with a warning log, never by throwing, since a stale/unplugged selection
    /// should degrade to "record something" rather than block the whole session
    /// (`docs/design/10-audio-input-selection.md` section 5.1).
    private func configureInputDevice(deviceUID: String?, on inputNode: AVAudioInputNode) {
        guard let deviceUID else {
            return
        }

        guard let deviceID = Self.resolveDeviceID(forUID: deviceUID) else {
            logger.warning("audio input device not found for UID \(deviceUID, privacy: .public); falling back to the system default input")
            return
        }

        guard let audioUnit = inputNode.audioUnit else {
            logger.warning("input node audio unit is unavailable; falling back to the system default input")
            return
        }

        var currentDevice = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &currentDevice,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            logger.warning("failed to set input device for UID \(deviceUID, privacy: .public) (status: \(status, privacy: .public)); falling back to the system default input")
        }
    }

    /// Resolves a CoreAudio device UID to an `AudioDeviceID` via
    /// `kAudioHardwarePropertyTranslateUIDToDevice`. Returns `nil` if the UID does not match any
    /// currently available device (e.g. it was unplugged since the caller's selection was made).
    private static func resolveDeviceID(forUID uid: String) -> AudioDeviceID? {
        var deviceID = AudioDeviceID.unknown
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var uidRef = uid as CFString
        let status = withUnsafeMutablePointer(to: &uidRef) { uidPointer -> OSStatus in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<CFString>.size),
                uidPointer,
                &dataSize,
                &deviceID
            )
        }

        guard status == noErr, deviceID != .unknown else {
            return nil
        }
        return deviceID
    }

    /// Requests microphone access if not yet determined, and throws if the current (or
    /// resulting) authorization status is `denied` or `restricted`.
    private static func checkPermission() throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            // Dispatched onto `permissionQueue` rather than called directly, so the blocking
            // `semaphore.wait()` inside `requestAccessAndWait()` runs on a dedicated background
            // queue rather than implicitly on whatever thread this function happens to be called
            // from (see `permissionQueue`'s doc comment and the `start(bufferHandler:)` warning).
            guard permissionQueue.sync(execute: requestAccessAndWait) else {
                throw MicrophoneSourceError.permissionDenied
            }
        case .denied:
            throw MicrophoneSourceError.permissionDenied
        case .restricted:
            throw MicrophoneSourceError.permissionRestricted
        @unknown default:
            throw MicrophoneSourceError.permissionDenied
        }
    }

    /// Bridges `AVCaptureDevice.requestAccess(for:completionHandler:)` (which reports its result
    /// on an arbitrary, non-main queue) into a synchronous call, since `AudioSourceCapturing`
    /// (section 5) deliberately keeps `start(bufferHandler:)` non-`async` so callers control
    /// which thread it runs on. This blocks the calling thread until the user responds to the
    /// system permission prompt (or immediately, if already determined).
    private static func requestAccessAndWait() -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var granted = false
        AVCaptureDevice.requestAccess(for: .audio) { result in
            granted = result
            semaphore.signal()
        }
        semaphore.wait()
        return granted
    }

    private func process(inputBuffer: AVAudioPCMBuffer, when: AVAudioTime) {
        guard let converter, let bufferHandler else {
            return
        }

        // Capture the pre-conversion host time now, before calling `AVAudioConverter.convert`:
        // the converter's output `AVAudioPCMBuffer` cannot carry timing information, so `when`
        // (and the seconds value derived from it) must be read at this point and threaded through
        // separately rather than recovered afterwards (`docs/design/01-audio-capture.md` 7.1).
        if when.isHostTimeValid {
            let hostSeconds = AVAudioTime.seconds(forHostTime: when.hostTime)
            logger.debug("mic tap buffer at host time \(hostSeconds, privacy: .public)s, frames=\(inputBuffer.frameLength, privacy: .public)")
        } else {
            // `when` is still forwarded to `bufferHandler` below even in this case (the protocol
            // contract always pairs a buffer with a `when`), but this is unexpected in practice for
            // `AVAudioEngine.inputNode.installTap` callbacks, so surface it instead of staying silent:
            // a caller computing `elapsed` from an invalid host time would otherwise silently corrupt
            // `transcript.jsonl` timestamps with no diagnostic trail (section 7.1).
            logger.warning("mic tap buffer arrived with an invalid host time; downstream elapsed/timestamp computation for this buffer may be inaccurate")
        }

        let outputFrameCapacity = max(
            1,
            AVAudioFrameCount(
                ceil(Double(inputBuffer.frameLength) * targetFormat.sampleRate / inputBuffer.format.sampleRate)
            )
        )
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCapacity) else {
            logger.warning("failed to allocate mic output buffer; dropping this buffer")
            return
        }

        var conversionError: NSError?
        var providedInput = false
        // Single-shot pattern: the converter is fed `inputBuffer` exactly once and reports
        // `.noDataNow` afterwards, so one call to `convert` yields exactly the frames that
        // correspond to this one input buffer's time span (section 7.1, point 3) — no frame-level
        // apportionment is needed for the `when` timestamp forwarded below.
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outputStatus in
            if providedInput {
                outputStatus.pointee = .noDataNow
                return nil
            }

            providedInput = true
            outputStatus.pointee = .haveData
            return inputBuffer
        }

        guard status != .error, conversionError == nil else {
            // Drop this single buffer and keep processing subsequent ones (section 9, failure
            // mode #6). Unlike Chirami (which drops silently), Kikimi always logs the drop.
            logger.warning("mic buffer conversion dropped: \(conversionError?.localizedDescription ?? "unknown", privacy: .public)")
            return
        }
        guard outputBuffer.frameLength > 0 else {
            return
        }

        bufferHandler(outputBuffer, when)
    }

    private func cleanup() {
        isRunning = false
        converter = nil
        bufferHandler = nil
    }
}
