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
/// `MicrophoneCapture.swift`, with three deliberate differences: the pre-conversion `AVAudioTime`
/// is preserved and forwarded (section 7.1) instead of being discarded, because Kikimi needs it
/// to compute `elapsed` for `transcript.jsonl`; an invalid post-configuration input format
/// (e.g. zero input devices) is guarded against and surfaced as a thrown error instead of being
/// left to crash `installTap` with an Objective-C exception (section 5.1); and, mid-recording,
/// this type reacts to `AVAudioEngine.configurationChangeNotification` and rebuilds the tap
/// against whatever input device is current (section 8, failure mode #9) -- `inputNode` otherwise
/// stays bound to the device that was active at the last `engine.start()`, so it never follows a
/// later system-default switch (e.g. Sound settings, AirPods connecting) on its own.
final class MicrophoneSource: AudioSourceCapturing {
    private let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "MicrophoneSource")

    private let engine: AVAudioEngine
    private let targetFormat: AVAudioFormat
    private let tapBufferSize: AVAudioFrameCount

    /// The CoreAudio device UID to route the microphone input to, or `nil` to follow the system
    /// default input device. Resolved to an `AudioDeviceID` in `configureInputDevice(on:)`
    /// (`docs/design/10-audio-input-selection.md` section 5.1).
    private let deviceUID: String?

    /// Serializes every mutation of `engine`/`converter`/`isRunning`/`configurationChangeObserver`:
    /// `start(bufferHandler:)`, `stop()`, and the configuration-change-triggered reconfiguration
    /// (`reconfigureOnControlQueue()`) can each be triggered from a different thread -- the
    /// notification in particular can be posted from an arbitrary CoreAudio thread -- so without
    /// this queue two of them could mutate the same `AVAudioEngine`/`AVAudioInputNode` concurrently.
    /// All private `...OnControlQueue()` methods below must only run while on this queue.
    private let controlQueue = DispatchQueue(label: "io.github.uphy.Kikimi.MicrophoneSource.control")

    private var converter: AVAudioConverter?
    private var bufferHandler: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?
    private var isRunning = false
    /// Non-`nil` only while `isRunning`; registered in `startOnControlQueue` right after
    /// `engine.start()` succeeds, torn down in `stopOnControlQueue()`/`stopAfterReconfigureFailure()`.
    private var configurationChangeObserver: NSObjectProtocol?

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

    deinit {
        // `deinit` has exclusive access to `self`, so no `controlQueue` hop is needed here.
        // Without this, an instance deallocated while running (i.e. without a `stop()` call)
        // would leak its observer token in `NotificationCenter`.
        removeConfigurationChangeObserver()
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
    ///
    /// - Note: Permission is deliberately checked *before* the `alreadyRunning` guard (which lives
    ///   inside `startOnControlQueue()`), so the potentially-blocking TCC wait never runs while
    ///   holding `controlQueue`. Consequence: a redundant `start()` on an unauthorized process
    ///   surfaces `.permissionDenied` rather than `.alreadyRunning` -- acceptable because
    ///   `AudioCapture` never double-starts a source.
    func start(bufferHandler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) throws {
        try Self.checkPermission()

        try controlQueue.sync {
            try startOnControlQueue(bufferHandler: bufferHandler)
        }
    }

    func stop() {
        controlQueue.sync {
            stopOnControlQueue()
        }
    }

    /// Must only run on `controlQueue` (see its doc comment). Shared by the initial `start()` call
    /// only -- reconfiguration after a device change is `reconfigureOnControlQueue()` below, which
    /// duplicates the device-configure/format-guard/converter/tap steps rather than calling into
    /// this method, since it additionally has to remove the previous tap and stop/restart the
    /// already-running engine first.
    private func startOnControlQueue(bufferHandler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) throws {
        guard !isRunning else {
            throw MicrophoneSourceError.alreadyRunning
        }

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

        installTap(on: inputNode, format: inputFormat, converter: converter, bufferHandler: bufferHandler)

        do {
            try engine.start()
            isRunning = true
            installConfigurationChangeObserver()
        } catch {
            inputNode.removeTap(onBus: 0)
            cleanupOnControlQueue()
            throw MicrophoneSourceError.engineFailed(error.localizedDescription)
        }
    }

    /// Must only run on `controlQueue`.
    private func stopOnControlQueue() {
        removeConfigurationChangeObserver()

        guard isRunning else {
            cleanupOnControlQueue()
            return
        }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        cleanupOnControlQueue()
    }

    // MARK: - Mid-recording device change (configuration-change notification)

    /// Registered right after `engine.start()` succeeds; torn down in `stopOnControlQueue()` and
    /// in `stopAfterReconfigureFailure()`. Scoped to `object: engine` so a test that constructs
    /// several `MicrophoneSource` instances (each with its own injected `AVAudioEngine`) never
    /// cross-delivers one instance's configuration changes to another's observer.
    private func installConfigurationChangeObserver() {
        configurationChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.handleConfigurationChangeNotification()
        }
    }

    private func removeConfigurationChangeObserver() {
        guard let configurationChangeObserver else {
            return
        }
        NotificationCenter.default.removeObserver(configurationChangeObserver)
        self.configurationChangeObserver = nil
    }

    /// `AVAudioEngineConfigurationChange` can be posted on an arbitrary thread (not necessarily
    /// `controlQueue`), so this only hops onto `controlQueue`; the actual rebuild happens in
    /// `reconfigureOnControlQueue()`, which then runs serialized against `start`/`stop`.
    private func handleConfigurationChangeNotification() {
        controlQueue.async { [weak self] in
            self?.reconfigureOnControlQueue()
        }
    }

    /// Reacts to a hardware configuration change: the system default input device switching
    /// (Sound settings, AirPods connecting/disconnecting, etc.) when `deviceUID == nil`, or an
    /// explicitly selected device disappearing/changing format when `deviceUID != nil`.
    /// `AVAudioEngine.inputNode` binds to whatever input device was active at the last
    /// `engine.start()` and does not itself follow later changes
    /// (`docs/design/10-audio-input-selection.md` section 8, failure mode #9), so this removes the
    /// stale tap, re-resolves the configured device, rebuilds the converter against the *new*
    /// input format (device changes generally change sample rate/channel count too), reinstalls
    /// the tap, and restarts the engine.
    ///
    /// A few hundred ms of dropped audio during the rebuild is accepted; downstream `elapsed`
    /// computation stays correct across the gap because it is derived from `AVAudioTime`'s host
    /// clock (`AudioCapture.elapsed(from:recordingStartHostTime:)`), not from a running sample
    /// count, so a restart never introduces a timestamp discontinuity.
    ///
    /// If the rebuild fails at any step, this logs `.error` and tears capture down via
    /// `stopAfterReconfigureFailure()` instead of retrying: `AVAudioEngineConfigurationChange` can
    /// in principle keep firing (e.g. flapping hardware), and retrying indefinitely from inside
    /// this handler would risk a tight failure loop with no backoff. The caller only learns about
    /// this by buffers silently stopping (`AudioSourceCapturing` has no mid-stream failure
    /// callback for the microphone side, unlike `SystemAudioSource.onDegraded`); widening that
    /// contract is left for a follow-up if this proves insufficient in practice.
    private func reconfigureOnControlQueue() {
        guard isRunning else {
            // `stop()` already won the race against this notification (or it fired for an engine
            // this instance never actually started) -- nothing to reconfigure.
            return
        }

        let inputNode = engine.inputNode
        inputNode.removeTap(onBus: 0)
        engine.stop()

        // Re-resolve the configured device. For an explicit `deviceUID` this restores the same
        // routing (possibly against a new format); for `deviceUID == nil` this is the point where
        // the *new* system default input actually takes effect.
        configureInputDevice(deviceUID: deviceUID, on: inputNode)

        // `testReconfigureFormatOverride` lets tests substitute a deterministic
        // format here instead of depending on whatever real input device (if any) the test
        // machine happens to expose -- see the "Testable seams" section below. Always `nil` in
        // production.
        let inputFormat = testReconfigureFormatOverride ?? inputNode.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            let formatDescription = "sampleRate=\(inputFormat.sampleRate), channelCount=\(inputFormat.channelCount)"
            logger.error("microphone reconfiguration after a device change failed: invalid input format (\(formatDescription, privacy: .public)); stopping microphone capture")
            stopAfterReconfigureFailure()
            return
        }

        guard let newConverter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            logger.error("microphone reconfiguration after a device change failed: unable to create an audio converter for the new input format; stopping microphone capture")
            stopAfterReconfigureFailure()
            return
        }
        converter = newConverter

        guard let bufferHandler else {
            // Unreachable while `isRunning` (the two are only ever set together in
            // `startOnControlQueue()`/`markStartedForTesting`), but tear down explicitly rather
            // than install a tap whose buffers would have nowhere to go.
            logger.error("microphone reconfiguration after a device change failed: buffer handler is missing; stopping microphone capture")
            stopAfterReconfigureFailure()
            return
        }
        installTap(on: inputNode, format: inputFormat, converter: newConverter, bufferHandler: bufferHandler)

        do {
            try engine.start()
            logger.info("microphone input reconfigured after a device change (\(inputFormat.sampleRate, privacy: .public)Hz, \(inputFormat.channelCount, privacy: .public)ch)")
        } catch {
            logger.error("microphone reconfiguration after a device change failed: engine restart error: \(error.localizedDescription, privacy: .public); stopping microphone capture")
            stopAfterReconfigureFailure()
        }
    }

    /// Installs the conversion tap. The closure captures `converter`/`bufferHandler` by value
    /// instead of reading `self.converter`/`self.bufferHandler`: tap callbacks arrive on a
    /// CoreAudio thread and `removeTap(onBus:)` does not wait for in-flight callbacks, so an
    /// unsynchronized property read in the callback could race with
    /// `reconfigureOnControlQueue()` reassigning `converter` mid-recording. With the capture,
    /// an in-flight callback from the old tap keeps using the (still-valid) old converter and
    /// the shared mutable state never crosses threads.
    private func installTap(
        on inputNode: AVAudioInputNode,
        format: AVAudioFormat,
        converter: AVAudioConverter,
        bufferHandler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) {
        inputNode.installTap(onBus: 0, bufferSize: tapBufferSize, format: format) { [weak self] buffer, when in
            self?.process(inputBuffer: buffer, when: when, converter: converter, bufferHandler: bufferHandler)
        }
    }

    /// Tears capture down the same way `stopOnControlQueue()` would, without a caller-side
    /// `stop()` call -- used when `reconfigureOnControlQueue()` cannot rebuild a working input.
    /// Leaves `isRunning == false` (matching `stop()`'s post-condition) and removes the
    /// configuration-change observer, so hardware that keeps flapping cannot re-enter this failure
    /// path repeatedly.
    private func stopAfterReconfigureFailure() {
        engine.inputNode.removeTap(onBus: 0)
        removeConfigurationChangeObserver()
        cleanupOnControlQueue()
    }

    // MARK: - Testable seams (`MicrophoneSourceTests`)
    //
    // `start(bufferHandler:)` calls `checkPermission()` first, which can synchronously block on
    // the system microphone-permission prompt (or, on a process with no
    // `NSMicrophoneUsageDescription`, crash) -- unsafe to run inside a test process, exactly like
    // `DictationAudioInputTests`'s documented reason for never calling through to
    // `MicrophoneSource.start`. These seams let `MicrophoneSourceTests` exercise the
    // configuration-change reconfiguration logic directly instead, using a real `AVAudioEngine`
    // subclass that overrides only `start()` (never touching TCC/hardware capture).

    /// Test-only override for the input format `reconfigureOnControlQueue()` resolves against.
    /// `nil` (the production behavior) always falls through to the real
    /// `AVAudioInputNode.inputFormat(forBus:)` query. Only safe to set to a genuinely *invalid*
    /// format (zero sample rate/channel count, as `MicrophoneSourceTests` does): the real
    /// `AVAudioNode.installTap(onBus:bufferSize:format:block:)` validates its `format:` argument
    /// against the node's actual hardware-derived format and crashes on a mismatch, so a "valid
    /// but different from the real device" override would crash instead of simulating a
    /// successful reconfigure -- the invalid-format branch is safe precisely because it returns
    /// before ever reaching `installTap`.
    var testReconfigureFormatOverride: AVAudioFormat?

    /// Puts this instance into the same internal state `startOnControlQueue()` leaves it in once
    /// a real `engine.start()` succeeds -- `isRunning`, `bufferHandler`, and the
    /// configuration-change observer -- without requiring microphone permission or a real capture
    /// session. Deliberately leaves `converter` untouched (`nil`) so a test can distinguish "never
    /// reconfigured" from "reconfigured" via `converterIdentityForTesting`.
    func markStartedForTesting(bufferHandler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) {
        controlQueue.sync {
            isRunning = true
            self.bufferHandler = bufferHandler
            installConfigurationChangeObserver()
        }
    }

    /// Synchronously runs the same reconfiguration `handleConfigurationChangeNotification()` would
    /// perform asynchronously off a real notification, blocking until it completes so assertions
    /// can run immediately after this returns.
    func triggerConfigurationChangeForTesting() {
        controlQueue.sync {
            reconfigureOnControlQueue()
        }
    }

    var isRunningForTesting: Bool {
        controlQueue.sync { isRunning }
    }

    /// `nil` when `converter` is `nil`; otherwise a value that changes identity whenever
    /// `converter` is reassigned to a new instance -- used to assert "reconfiguration rebuilt the
    /// converter" without `AVAudioConverter` needing to be `Equatable`.
    var converterIdentityForTesting: ObjectIdentifier? {
        controlQueue.sync { converter.map(ObjectIdentifier.init) }
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

    private func process(
        inputBuffer: AVAudioPCMBuffer,
        when: AVAudioTime,
        converter: AVAudioConverter,
        bufferHandler: (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) {
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

    /// Must only run on `controlQueue`.
    private func cleanupOnControlQueue() {
        isRunning = false
        converter = nil
        bufferHandler = nil
    }
}
