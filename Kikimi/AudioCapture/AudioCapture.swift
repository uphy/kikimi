import AVFoundation
import Foundation
import OSLog
import os

// NOTE: `AudioSourceKind` / `AudioCaptureConfig` / `AudioCaptureState` / `AudioCaptureError` /
// `AudioCaptureDelegate` / `AudioSourceCapturing` are defined in `AudioCaptureTypes.swift`
// (single source of truth for this component's public types; see that file and
// `docs/design/01-audio-capture.md` section 5). This file defines only the `AudioCapture`
// facade class itself (sections 3/5/5.1/6/7/9/12).

// MARK: - AudioCapture

/// Facade over the microphone and system audio capture streams: converts both to 16kHz mono,
/// persists them to `audio/mic.wav` / `audio/system.wav`, and forwards converted buffers
/// downstream via `AudioCaptureDelegate`.
///
/// Deliberately a plain `final class`, not an `actor` / `@MainActor` (section 5.1): audio callbacks
/// arrive on realtime-sensitive threads owned by `AVAudioEngine` / CoreAudio, and this type needs
/// explicit control over which `DispatchQueue` they hop to rather than leaving it to the Swift
/// concurrency runtime's executor scheduling (mirrors Chirami's `DispatchQueue`-based `ioQueue` pattern).
final class AudioCapture {
    private let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "AudioCapture")

    private let audioDirectory: URL
    private let config: AudioCaptureConfig
    /// Zero-based recording-segment index this instance writes for (kikimi.md 4 章: one
    /// `AudioCapture` instance per recording segment, created fresh on every start/resume/reopen).
    /// Determines the WAV file names this instance opens: `mic_NNN.wav`/`system_NNN.wav`, `NNN`
    /// zero-padded to 3 digits.
    private let recordingIndex: Int

    /// `nil` when `selection.mic.enabled == false` (`docs/design/10-audio-input-selection.md`
    /// section 5.2): a disabled source is never constructed, never opens a WAV writer, and is
    /// never started -- not merely started-and-ignored.
    private let microphoneSource: AudioSourceCapturing?
    /// `nil` when `selection.system.enabled == false`. See `microphoneSource` above.
    private let systemAudioSource: AudioSourceCapturing?

    /// Captured at `init` time; non-nil when `sessions/<id>/audio/` could not be created.
    /// `init` itself never throws (section 5), so this is surfaced by `start()` instead (failure
    /// mode #8).
    private let sessionDirectoryCreationError: String?

    weak var delegate: AudioCaptureDelegate?

    /// Single serial queue backing every `AudioCaptureDelegate` callback and every `state` write
    /// (section 5.1). Entirely independent of each `WavFileWriter`'s own `writerQueue` (section 3/8):
    /// callers hop to `eventQueue` and to a `writerQueue` independently from the originating audio
    /// callback thread, so neither queue can block on the other.
    private let eventQueue = DispatchQueue(label: "io.github.uphy.Kikimi.AudioCapture.event")

    /// Backing storage for `state`. Written only while executing on `eventQueue` (via `setState`
    /// and friends below); read synchronously from any thread through the lock itself (section 5.1).
    private let stateStorage = OSAllocatedUnfairLock<AudioCaptureState>(initialState: .idle)

    /// `micWriter`/`systemWriter`, grouped behind a single lock. `handleBuffer` reads these from
    /// the originating audio-callback thread (mic tap thread / system audio IOProc thread) while
    /// `start()`/`stop()` write them from the caller's thread with no queue hop in between, so a
    /// plain `var` pair would be a data race; `OSAllocatedUnfairLock` mirrors the pattern already
    /// used for `micWriteGaveUp`/`recordingStartHostTimeStorage` below.
    private struct Writers {
        var mic: WavFileWriter?
        var system: WavFileWriter?
    }
    private let writersStorage = OSAllocatedUnfairLock<Writers>(initialState: Writers())

    /// Host time (`mach_absolute_time()` domain) captured the moment `start()` succeeds
    /// (`recordingStartHostTime`, section 7). Read from audio-callback threads (via `handleBuffer`)
    /// and written from `start()`'s caller thread, so it is lock-protected like `micWriteGaveUp`
    /// below rather than a plain `var`.
    private let recordingStartHostTimeStorage = OSAllocatedUnfairLock<UInt64>(initialState: 0)

    /// Guards against continuing to call `WavFileWriter.append` (and re-logging) once a stream's
    /// file writing has failed once (section 8/9, failure mode #7: "give up on further appends").
    private let micWriteGaveUp = OSAllocatedUnfairLock<Bool>(initialState: false)
    private let systemWriteGaveUp = OSAllocatedUnfairLock<Bool>(initialState: false)

    var state: AudioCaptureState {
        stateStorage.withLock { $0 }
    }

    /// - Parameters:
    ///   - selection: Which sources to capture from and where (`docs/design/10-audio-input-selection.md`
    ///     section 5.1). A source whose `enabled` flag is `false` is never constructed here --
    ///     not even when an explicit `microphoneSource`/`systemAudioSource` override is passed in
    ///     for testing -- so `start()` can later skip it entirely (no WAV writer opened, no
    ///     `start()` call, no permission prompt; section 5.2).
    init(
        sessionDirectory: URL,
        selection: AudioInputSelection = .default,
        recordingIndex: Int = 0,
        config: AudioCaptureConfig = AudioCaptureConfig(),
        microphoneSource: AudioSourceCapturing? = nil,
        systemAudioSource: AudioSourceCapturing? = nil
    ) {
        self.config = config
        self.recordingIndex = recordingIndex

        let audioDirectory = sessionDirectory.appendingPathComponent("audio", isDirectory: true)
        self.audioDirectory = audioDirectory
        do {
            try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
            self.sessionDirectoryCreationError = nil
        } catch {
            self.sessionDirectoryCreationError = error.localizedDescription
        }

        let testInputPath = ProcessInfo.processInfo.environment["KIKIMI_TEST_INPUT"]

        if selection.mic.enabled {
            if let microphoneSource {
                self.microphoneSource = microphoneSource
            } else if let testInputPath {
                self.microphoneSource = TestFileAudioSource(
                    fileURL: URL(fileURLWithPath: testInputPath),
                    chunkFrameCount: config.micTapBufferSize
                )
            } else {
                self.microphoneSource = MicrophoneSource(
                    deviceUID: selection.mic.deviceUid,
                    targetSampleRate: config.sampleRate,
                    targetChannels: config.channels,
                    tapBufferSize: config.micTapBufferSize
                )
            }
        } else {
            self.microphoneSource = nil
        }

        if selection.system.enabled {
            if let systemAudioSource {
                self.systemAudioSource = systemAudioSource
            } else if let testInputPath {
                self.systemAudioSource = TestFileAudioSource(
                    fileURL: URL(fileURLWithPath: testInputPath),
                    chunkFrameCount: config.micTapBufferSize
                )
            } else {
                self.systemAudioSource = SystemAudioSource(
                    includedBundleId: selection.system.bundleId,
                    targetSampleRate: config.sampleRate,
                    targetChannels: config.channels
                )
            }
        } else {
            self.systemAudioSource = nil
        }

        // Wire up mid-recording stall detection (section 9, failure mode #5) if the resolved
        // source is the production `SystemAudioSource`. `AudioSourceCapturing` intentionally has
        // no `onDegraded` in its protocol surface (section 5): only the concrete implementation
        // that can actually stall needs it, so fakes/`TestFileAudioSource` are unaffected.
        if let productionSystemSource = self.systemAudioSource as? SystemAudioSource {
            productionSystemSource.onDegraded = { [weak self] error in
                self?.handleSystemAudioDegraded(error)
            }
        }
    }

    // MARK: - start / stop

    /// Order: open `mic.wav` (if mic is enabled) -> start both enabled sources (microphone
    /// permission is confirmed as part of `MicrophoneSource.start(bufferHandler:)`) -> best-effort
    /// open `system.wav` (if system audio is enabled) and start system audio. On any failure,
    /// `state` is reset to `.idle`, any `WavFileWriter`s already opened are closed *and their
    /// placeholder files removed* (so a denied permission never leaves an empty `mic.wav`/`system.wav`
    /// behind), and the error is thrown (the caller stays in Draft).
    ///
    /// A source disabled via `selection` (`microphoneSource`/`systemAudioSource` is `nil`) is
    /// skipped entirely here: no WAV writer is opened for it, `start()` is never called on it, and
    /// it never factors into the fatal/degrade decision below (`docs/design/10-audio-input-selection.md`
    /// section 5.2's "無効化されたソースは fatal 判定の分母から外れる"). This is the only thing this
    /// design changes about the failure-mode logic; everything else -- mic failing is fatal when
    /// mic is enabled, system failing degrades to mic-only when mic is also enabled and running --
    /// matches the pre-existing behavior.
    ///
    /// `mic.wav` failing to open is fatal when mic is enabled, matching microphone itself being
    /// mandatory (section 9's "microphone is required" principle). `system.wav` failing to open (a
    /// filesystem-level failure, not a permission one) is instead treated as a system-audio
    /// degradation like any other failure (section 9, failure mode #3/#6) *when mic is also
    /// enabled*; when mic is disabled, system is the only enabled source and any of its failures
    /// (including a `system.wav` open failure) are fatal, surfaced as `.systemAudioStartFailed`.
    func start() async throws {
        guard setStateIfIdle(.starting) else {
            throw AudioCaptureError.alreadyRunning
        }

        do {
            if let sessionDirectoryCreationError {
                throw AudioCaptureError.sessionDirectoryUnavailable(sessionDirectoryCreationError)
            }

            // Defensive: the caller (ViewModel) is expected to guard `hasEnabledSource` before
            // ever calling `start()` and keep the recording button disabled otherwise (section
            // 5.2, row 4), but `AudioCapture` does not trust that invariant blindly.
            guard microphoneSource != nil || systemAudioSource != nil else {
                throw AudioCaptureError.allSourcesUnavailable
            }

            if microphoneSource != nil {
                let micWriter = try openWriter(fileName: Self.micFileName(recordingIndex: recordingIndex))
                writersStorage.withLock { $0.mic = micWriter }
            }

            // system_NNN.wav is opened best-effort, and only attempted if system audio is enabled
            // at all: a filesystem-level failure here degrades exactly like any other system-audio
            // failure mode rather than aborting the whole recording (when mic is also enabled).
            var systemError: Error?
            if systemAudioSource != nil {
                do {
                    let systemWriter = try openWriter(fileName: Self.systemFileName(recordingIndex: recordingIndex))
                    writersStorage.withLock { $0.system = systemWriter }
                } catch {
                    systemError = error
                }
            }

            micWriteGaveUp.withLock { $0 = false }
            systemWriteGaveUp.withLock { $0 = false }

            // Both enabled sources are attempted regardless of each other's outcome; only their
            // combined result determines whether `start()` throws, throws with mic-specific
            // detail, or succeeds in a degraded state (section 9, failure modes #1-#4).
            // Microphone permission confirmation happens inside
            // `MicrophoneSource.start(bufferHandler:)` itself.
            // Set before either source's `start()` is called: a mic buffer callback can arrive
            // before `systemAudioSource.start()` below even returns, and `handleBuffer` reads this
            // value to compute `elapsed`. Setting it only after both `start()` calls complete would
            // let early callbacks compute `elapsed` against the stale (zero) initial value.
            recordingStartHostTimeStorage.withLock { $0 = mach_absolute_time() }

            var micError: Error?
            if let microphoneSource {
                do {
                    try microphoneSource.start { [weak self] buffer, time in
                        self?.handleBuffer(buffer, time: time, source: .mic)
                    }
                } catch {
                    micError = error
                }
            }

            // Only attempt the system audio source itself if system.wav actually opened (or system
            // audio is disabled, in which case `systemAudioSource` is `nil` and this is a no-op);
            // there is nothing to persist system audio to otherwise, so the whole system stream is
            // degraded.
            if systemError == nil, let systemAudioSource {
                do {
                    try systemAudioSource.start { [weak self] buffer, time in
                        self?.handleBuffer(buffer, time: time, source: .system)
                    }
                } catch {
                    systemError = error
                }
            }

            try resolveStartOutcome(micError: micError, systemError: systemError)
        } catch {
            microphoneSource?.stop()
            systemAudioSource?.stop()
            let writers = writersStorage.withLock { current -> Writers in
                let opened = current
                current = Writers()
                return opened
            }
            writers.mic?.close()
            writers.system?.close()
            // Recording never actually started in this path, so don't leave an empty placeholder
            // WAV file behind (e.g. when microphone permission is denied after mic_NNN.wav was opened).
            try? FileManager.default.removeItem(at: audioDirectory.appendingPathComponent(Self.micFileName(recordingIndex: recordingIndex)))
            try? FileManager.default.removeItem(at: audioDirectory.appendingPathComponent(Self.systemFileName(recordingIndex: recordingIndex)))
            setState(.idle)
            throw error
        }
    }

    /// Applies the section 5.2 start() outcome matrix given which sources are enabled
    /// (`microphoneSource`/`systemAudioSource` non-`nil`) and whether each one failed to start.
    /// Either sets `state` to `.running` (possibly degraded) or throws, matching the pre-existing
    /// behavior for the "both enabled" row and adding the two single-source rows.
    private func resolveStartOutcome(micError: Error?, systemError: Error?) throws {
        switch (microphoneSource != nil, systemAudioSource != nil) {
        case (true, true):
            if micError != nil, systemError != nil {
                microphoneSource?.stop()
                systemAudioSource?.stop()
                throw AudioCaptureError.allSourcesUnavailable
            }
            if let micError {
                systemAudioSource?.stop()
                throw Self.mapMicrophoneError(micError)
            }
            if let systemError {
                setState(.running(activeSources: [.mic]))
                let message = Self.message(for: systemError)
                logger.warning("System audio unavailable; continuing with microphone only: \(message, privacy: .public)")
                eventQueue.async { [weak self] in
                    guard let self else { return }
                    self.delegate?.audioCapture(self, didDegrade: .system, error: .systemAudioUnavailable(message: message))
                }
            } else {
                setState(.running(activeSources: [.mic, .system]))
            }

        case (true, false):
            // System audio is disabled outright (not merely unavailable): section 5.2 row 2 --
            // no didDegrade, since an intentional disablement is not a degradation.
            if let micError {
                throw Self.mapMicrophoneError(micError)
            }
            setState(.running(activeSources: [.mic]))

        case (false, true):
            // Mic is disabled, so system audio is the sole enabled source and has no fallback:
            // any failure here is fatal (section 5.2 row 3), unlike the mic-enabled case above
            // where the same failure degrades to mic-only.
            if let systemError {
                systemAudioSource?.stop()
                throw AudioCaptureError.systemAudioStartFailed(message: Self.message(for: systemError))
            }
            setState(.running(activeSources: [.system]))

        case (false, false):
            // Unreachable: guarded by the `hasEnabledSource`-equivalent check at the top of
            // `start()`. Kept exhaustive rather than `fatalError`-ing so a future refactor that
            // removes that guard fails safe instead of crashing.
            throw AudioCaptureError.allSourcesUnavailable
        }
    }

    /// Stops both sources, then flushes the final WAV headers and closes both files.
    /// Safe to call more than once (and safe to call concurrently); calls beyond the first are a no-op.
    func stop() async {
        guard beginStoppingIfNeeded() else {
            return
        }

        microphoneSource?.stop()
        systemAudioSource?.stop()

        let writers = writersStorage.withLock { current -> Writers in
            let opened = current
            current = Writers()
            return opened
        }
        writers.mic?.close()
        writers.system?.close()

        setState(.stopped)

        eventQueue.async { [weak self] in
            guard let self else { return }
            self.delegate?.audioCaptureDidStop(self)
        }
    }

    // MARK: - State helpers (writes always happen while running on `eventQueue`, section 5.1)

    private func setState(_ newValue: AudioCaptureState) {
        eventQueue.sync {
            stateStorage.withLock { $0 = newValue }
        }
    }

    private func setStateIfIdle(_ newValue: AudioCaptureState) -> Bool {
        eventQueue.sync {
            stateStorage.withLock { current in
                guard current == .idle else { return false }
                current = newValue
                return true
            }
        }
    }

    private func beginStoppingIfNeeded() -> Bool {
        eventQueue.sync {
            stateStorage.withLock { current in
                switch current {
                case .idle, .stopping, .stopped:
                    return false
                case .starting, .running:
                    current = .stopping
                    return true
                }
            }
        }
    }

    /// Reacts to `SystemAudioSource.onDegraded` firing mid-recording (section 9, failure mode #5):
    /// drops `.system` from `activeSources` (only if it is still present -- this fires at most
    /// once, but stays defensive) and reports the degradation the same way a start-time system
    /// audio failure would.
    ///
    /// Branches its wording depending on whether `activeSources` becomes empty as a result
    /// (`docs/design/10-audio-input-selection.md` section 5.2): when mic is enabled and still
    /// running, this is the pre-existing "continuing with microphone only" message. When mic is
    /// disabled and system audio was the sole active source, "continuing with microphone only"
    /// would be false -- recording continues (per "録音は絶対に止めない"), but silently, with no
    /// active source left, so the wording instead tells the caller to stop and check.
    private func handleSystemAudioDegraded(_ error: Error) {
        let activeSourcesAfter: Set<AudioSourceKind>? = eventQueue.sync {
            stateStorage.withLock { current -> Set<AudioSourceKind>? in
                guard case .running(let activeSources) = current, activeSources.contains(.system) else {
                    return nil
                }
                let remaining = activeSources.subtracting([.system])
                current = .running(activeSources: remaining)
                return remaining
            }
        }
        guard let activeSourcesAfter else {
            return
        }

        let underlyingMessage = Self.message(for: error)
        let message: String
        if activeSourcesAfter.isEmpty {
            message = "no active audio sources remain (microphone is disabled for this recording); recording continues writing silence -- \(underlyingMessage)"
            logger.warning("System audio degraded mid-recording; no active sources remain (mic disabled): \(underlyingMessage, privacy: .public)")
        } else {
            message = underlyingMessage
            logger.warning("System audio degraded mid-recording, continuing with microphone only: \(underlyingMessage, privacy: .public)")
        }
        eventQueue.async { [weak self] in
            guard let self else { return }
            self.delegate?.audioCapture(self, didDegrade: .system, error: .systemAudioUnavailable(message: message))
        }
    }

    // MARK: - Buffer handling

    /// Called synchronously on the originating source's own thread (mic tap thread / system audio
    /// IOProc thread). Hops independently to `eventQueue` and to the relevant `WavFileWriter`'s
    /// `writerQueue`; neither hop depends on the other, so disk I/O delays never propagate to the
    /// STT delegate path and vice versa (section 3).
    private func handleBuffer(_ buffer: AVAudioPCMBuffer, time: AVAudioTime, source: AudioSourceKind) {
        let recordingStartHostTime = recordingStartHostTimeStorage.withLock { $0 }
        let elapsed = Self.elapsed(from: time, recordingStartHostTime: recordingStartHostTime)

        eventQueue.async { [weak self] in
            guard let self else { return }
            self.delegate?.audioCapture(self, didCapture: buffer, source: source, elapsed: elapsed)
            if let level = Self.rms(of: buffer) {
                self.delegate?.audioCapture(self, didUpdateLevel: level, source: source)
            }
        }

        let writer: WavFileWriter?
        let gaveUp: OSAllocatedUnfairLock<Bool>
        switch source {
        case .mic:
            writer = writersStorage.withLock { $0.mic }
            gaveUp = micWriteGaveUp
        case .system:
            writer = writersStorage.withLock { $0.system }
            gaveUp = systemWriteGaveUp
        }

        guard let writer, gaveUp.withLock({ !$0 }) else {
            return
        }

        // `didCapture` above is dispatched independently of this: WAV persistence failures never
        // hold back the STT path (section 8: STT-side delegate notification continues regardless
        // of whether WAV writing succeeds).
        writer.append(buffer) { [weak self] error in
            guard let self else { return }
            gaveUp.withLock { $0 = true }
            let message = Self.message(for: error)
            self.logger.error("WAV write failed for \(source.rawValue, privacy: .public), giving up on further writes: \(message, privacy: .public)")
            self.eventQueue.async { [weak self] in
                guard let self else { return }
                self.delegate?.audioCapture(self, didDegrade: source, error: .fileWriteFailed(source: source, message: message))
            }
        }
    }

    /// Pure elapsed-time computation, kept as a `static` function so it can be unit tested with
    /// fixed host time values without depending on the wall clock (section 7/10).
    static func elapsed(from bufferTime: AVAudioTime, recordingStartHostTime: UInt64) -> TimeInterval {
        AVAudioTime.seconds(forHostTime: bufferTime.hostTime) - AVAudioTime.seconds(forHostTime: recordingStartHostTime)
    }

    private static func rms(of buffer: AVAudioPCMBuffer) -> Double? {
        guard let channelData = buffer.floatChannelData, buffer.frameLength > 0 else {
            return nil
        }
        let frameLength = Int(buffer.frameLength)
        let samples = channelData[0]
        var sumOfSquares: Double = 0
        for index in 0..<frameLength {
            let sample = Double(samples[index])
            sumOfSquares += sample * sample
        }
        return (sumOfSquares / Double(frameLength)).squareRoot()
    }

    /// `mic_NNN.wav`, `NNN` zero-padded to 3 digits (kikimi.md 4 章 directory layout).
    static func micFileName(recordingIndex: Int) -> String {
        String(format: "mic_%03d.wav", recordingIndex)
    }

    /// `system_NNN.wav`, `NNN` zero-padded to 3 digits (kikimi.md 4 章 directory layout).
    static func systemFileName(recordingIndex: Int) -> String {
        String(format: "system_%03d.wav", recordingIndex)
    }

    private func openWriter(fileName: String) throws -> WavFileWriter {
        do {
            return try WavFileWriter(
                fileURL: audioDirectory.appendingPathComponent(fileName),
                sampleRate: config.sampleRate,
                channels: config.channels,
                headerFlushInterval: config.headerFlushInterval
            )
        } catch {
            throw AudioCaptureError.sessionDirectoryUnavailable("\(fileName): \(Self.message(for: error))")
        }
    }

    /// Maps a `MicrophoneSource.start(bufferHandler:)` failure (or, in tests, a fake source's
    /// arbitrary `Error`) onto the corresponding `AudioCaptureError` case (section 9, failure
    /// modes #1/#2). A fake that already throws an `AudioCaptureError` directly (e.g. to simulate
    /// `.microphonePermissionDenied` in a unit test without touching real TCC state) passes through unchanged.
    private static func mapMicrophoneError(_ error: Error) -> AudioCaptureError {
        if let alreadyMapped = error as? AudioCaptureError {
            return alreadyMapped
        }
        if let micError = error as? MicrophoneSourceError {
            switch micError {
            case .permissionDenied:
                return .microphonePermissionDenied
            case .permissionRestricted:
                return .microphonePermissionRestricted
            case .alreadyRunning, .unableToCreateConverter, .engineFailed:
                return .microphoneEngineFailed(micError.localizedDescription)
            }
        }
        return .microphoneEngineFailed(message(for: error))
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
