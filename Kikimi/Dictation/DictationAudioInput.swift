import AVFoundation
import Foundation
import OSLog
import os

// MARK: - DictationAudioInput

/// A thin `MicrophoneSource` wrapper for the dictation feature
/// (`docs/design/25-dictation-mode.md` R2). Deliberately bypasses `AudioCapture`: that facade
/// requires a `sessionDirectory` and always opens a WAV writer, neither of which the base
/// dictation flow wants -- it is otherwise stateless. When `recordingURL` is supplied (dictation
/// history, `docs/design/29-dictation-history.md` §4.2/DH3), this type tees the mic buffers to a
/// `WavFileWriter` at that URL as well; with `recordingURL == nil` it never persists audio to disk.
///
/// Not `@MainActor`/an `actor`: `MicrophoneSource.start(bufferHandler:)` must not be called
/// directly from the main thread (it can synchronously block on the microphone permission
/// prompt), so this type's `start(samplesHandler:)` is a plain `async` function -- like
/// `AudioCapture.start()`, calling it hops off whatever actor context the caller is on.
final class DictationAudioInput {
    private let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "DictationAudioInput")

    private let source: MicrophoneSource
    /// `nil` means "don't record" (base dictation flow, DH1), or "not known yet" -- since the
    /// word-drop fix's 3a, `DictationController.handleHotkeyDown()` no longer awaits
    /// `beginHistoryEntryIfNeeded` before constructing this type (that would delay the mic's own
    /// startup by however long the history entry's directory-creation I/O takes), so this can stay
    /// `nil` at `init` and arrive later via `attachHistoryRecording(url:)` instead. Non-nil is
    /// where `WavFileWriter` is opened once `start` runs (design 29 §4.2).
    private let recordingURL: URL?
    /// Opened either in `start()` (when `recordingURL != nil` at construction time) or later via
    /// `attachHistoryRecording(url:)`. Stays `nil` for the lifetime of this instance if no
    /// destination is ever supplied, or if `WavFileWriter.init` throws (DH6: a failed writer
    /// degrades to an audio-less history entry, it never blocks capture/STT).
    ///
    /// Lock-guarded (not a plain `var`): `handleCapturedBuffer` reads it on the mic tap thread,
    /// while `attachHistoryRecording(url:)` can write it from the `@MainActor` caller once
    /// `beginHistoryEntryIfNeeded`'s await resolves -- both can now happen concurrently with
    /// capture already under way, unlike the pre-3a "always opened before `source.start`" ordering.
    private let wavWriterStorage = OSAllocatedUnfairLock<WavFileWriter?>(initialState: nil)

    /// Total number of samples handed to `samplesHandler` across the whole capture, accumulated
    /// on the mic tap thread (design 29 §4.2). Deliberately *not* counted on the `MainActor` side:
    /// by the time a `MainActor` `Task` observes a sample count, the tap may already have
    /// delivered more, undercounting `duration_ms` relative to what's actually on disk in
    /// `audio.wav` and causing `SegmentAudioPlayer` (which stops playback at `durationMs`) to cut
    /// off the tail of the recording. Read only after `stop()` returns.
    var recordedSampleCount: Int {
        captureStorage.withLock { $0.sampleCount }
    }

    /// Every sample handed to `samplesHandler`, in delivery order, for the key-up batch re-decode
    /// (`docs/design/31-dictation-two-pass-decode.md` TP4). Always empty when
    /// `accumulateSamples == false` (two-pass decode off keeps the pre-existing memory behavior
    /// byte for byte). Same read contract as `recordedSampleCount`: only after `stop()` returns.
    var recordedSamples: [Float] {
        captureStorage.withLock { $0.samples }
    }

    /// TP4: samples are accumulated only when two-pass decode wants them, decided once per
    /// utterance from the key-down config snapshot (`DictationController` constructs one instance
    /// per utterance).
    private let accumulateSamples: Bool

    private struct CaptureAccumulation {
        var sampleCount = 0
        var samples: [Float] = []
    }

    /// One lock for both the duration counter and the batch-decode sample buffer -- they are
    /// written together on the tap thread (design 29 §4.2's tap-side counting rationale applies to
    /// both: a `MainActor`-side copy could miss in-flight buffers).
    private let captureStorage = OSAllocatedUnfairLock<CaptureAccumulation>(initialState: CaptureAccumulation())

    /// Same rewrite cadence as the meeting-side `AudioCapture` default (`AudioCaptureConfig.headerFlushInterval`).
    /// An utterance is short and `stop()` always runs `WavFileWriter.close()` (which rewrites the
    /// final header), so this value has no real effect here -- it exists only because
    /// `WavFileWriter.init` requires it, and reusing the meeting-side default keeps the two call
    /// sites' semantics visibly aligned.
    private static let headerFlushInterval: TimeInterval = AudioCaptureConfig().headerFlushInterval

    /// - Parameters:
    ///   - deviceUID: `dictation.mic_device_uid`, or `nil`/empty for the system default
    ///     input device (mirrors `MicrophoneSource.deviceUID`'s own `nil`-means-default contract).
    ///   - recordingURL: destination for the tee'd WAV file (design 29's `EntryHandle.audioFileURL`),
    ///     or `nil` to keep the historical stateless behavior. The parent directory must already
    ///     exist (`DictationHistoryStore.beginEntry` creates it) -- `WavFileWriter` does not create
    ///     its parent directory.
    ///   - accumulateSamples: whether to keep the utterance's samples in memory for the key-up
    ///     batch re-decode (design 31 TP4; `dictation.two_pass_decode` at key-down time).
    init(
        deviceUID: String?,
        recordingURL: URL? = nil,
        accumulateSamples: Bool = false,
        engine: AVAudioEngine = AVAudioEngine()
    ) {
        let resolvedDeviceUID = (deviceUID?.isEmpty ?? true) ? nil : deviceUID
        self.source = MicrophoneSource(
            deviceUID: resolvedDeviceUID,
            engine: engine,
            targetSampleRate: 16_000,
            targetChannels: 1
        )
        self.recordingURL = recordingURL
        self.accumulateSamples = accumulateSamples
    }

    /// Starts capture and forwards each buffer's samples as `[Float]`, extracted on the tap's own
    /// callback thread before crossing into `samplesHandler` -- `AVAudioPCMBuffer` is not
    /// thread-safe, so the raw buffer itself must never be handed across a thread boundary
    /// (`SttEngine.feed(buffer:elapsedAtBufferStart:)`'s doc comment on the same hazard).
    ///
    /// `async` (even though `MicrophoneSource.start(bufferHandler:)` itself is synchronous) so
    /// that calling this from `DictationController` (`@MainActor`) never risks blocking the main
    /// thread: this type is a plain, non-isolated class, so an `async` method on it runs on the
    /// global concurrent executor rather than inheriting the caller's actor -- exactly the
    /// off-main-thread guarantee `MicrophoneSource.start(bufferHandler:)`'s own doc comment
    /// requires of its callers (it can synchronously block on the mic permission prompt).
    func start(samplesHandler: @escaping @Sendable ([Float]) -> Void) async throws {
        openWavWriterIfNeeded()

        try source.start { [weak self] buffer, _ in
            self?.handleCapturedBuffer(buffer, samplesHandler: samplesHandler)
        }
    }

    func stop() {
        source.stop()
        wavWriterStorage.withLock { $0 }?.close()
    }

    // MARK: - Testable seams

    /// Opens the WAV writer from `recordingURL` (design 29 §4.2 DH3), or leaves it `nil` if
    /// `recordingURL == nil`. A failed open logs a warning and leaves the writer `nil` (DH6):
    /// the utterance still proceeds, just without a history recording.
    ///
    /// Split out of `start()` and left at `internal` (not `private`) access so
    /// `DictationAudioInputTests` can exercise "recordingURL produces a valid WAV header" /
    /// "a missing parent directory degrades to no writer" directly -- without going through
    /// `start()`'s call into `MicrophoneSource.start`, which can synchronously block on the
    /// system microphone-permission prompt and is unsuitable to run inside a test process.
    func openWavWriterIfNeeded() {
        guard let recordingURL else {
            return
        }
        openWavWriter(at: recordingURL)
    }

    /// Opens the WAV writer *after* capture may already be under way (word-drop fix 3a):
    /// `DictationController.handleHotkeyDown()` calls this once `beginHistoryEntryIfNeeded`'s
    /// await resolves, rather than blocking `start()` on it. Whatever buffers `handleCapturedBuffer`
    /// already processed before this call lands are simply not tee'd to disk -- the same DH6
    /// "a failed writer degrades to an audio-less history entry" tolerance covers this narrower
    /// gap too, and it is strictly smaller than the previous behavior of delaying the mic itself.
    /// A no-op (via `openWavWriter(at:)`'s overwrite) if `start()` already opened one from a
    /// constructor-supplied `recordingURL` -- callers only ever use one of the two paths per
    /// utterance.
    func attachHistoryRecording(url: URL) {
        openWavWriter(at: url)
    }

    private func openWavWriter(at url: URL) {
        do {
            let writer = try WavFileWriter(
                fileURL: url,
                sampleRate: 16_000,
                channels: 1,
                headerFlushInterval: Self.headerFlushInterval
            )
            wavWriterStorage.withLock { $0 = writer }
        } catch {
            logger.warning("Failed to open dictation history WAV writer at \(url.path, privacy: .public), continuing without audio: \(String(describing: error), privacy: .public)")
        }
    }

    /// Called for every buffer `MicrophoneSource` delivers on its tap thread: tees `buffer` to
    /// the WAV writer (if any) before extracting samples, accumulates `recordedSampleCount`, then
    /// forwards the extracted samples to `samplesHandler`.
    ///
    /// Left at `internal` access (see `openWavWriterIfNeeded` above) so tests can drive it with a
    /// synthetic `AVAudioPCMBuffer` and assert `samplesHandler` still receives samples uninterrupted
    /// when no writer is open (a failed/not-yet-attached writer must never affect the STT path, DH6).
    func handleCapturedBuffer(_ buffer: AVAudioPCMBuffer, samplesHandler: @escaping @Sendable ([Float]) -> Void) {
        // Tee before `extractSamples` so a possible in-place conversion inside that call never
        // affects what `WavFileWriter` sees (design 29 §4.2 DH3): `buffer` is the converted
        // 16kHz mono Float32 standard-format buffer `MicrophoneSource` hands to this closure,
        // matching `WavFileWriter.append`'s input contract exactly.
        let wavWriter = wavWriterStorage.withLock { $0 }
        wavWriter?.append(buffer) { [weak self] error in
            guard let self else { return }
            self.logger.warning("Dictation history WAV append failed, giving up on further writes for this utterance: \(String(describing: error), privacy: .public)")
        }

        let samples = SttEngine.extractSamples(from: buffer)
        captureStorage.withLock {
            $0.sampleCount += samples.count
            if accumulateSamples {
                $0.samples.append(contentsOf: samples)
            }
        }
        samplesHandler(samples)
    }
}
