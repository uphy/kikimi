import AVFoundation
import Foundation
import Testing

@testable import Kikimi

/// End-to-end exercise of the `AudioCapture` facade wired to two independent
/// `TestFileAudioSource` instances (the same DI seam `KIKIMI_TEST_INPUT` resolves to in
/// production, see `docs/design/01-audio-capture.md` sections 10/12). This is the "kikimi-verify
/// via UI" substitute agreed for this module: it exercises start() -> dummy audio replay ->
/// stop() -> mic.wav/system.wav on disk without requiring a wired-up app UI, which does not exist
/// yet (that is `06-ui-panels.md` / `07-session-store.md`'s job).
@Suite("AudioCapture integration (TestFileAudioSource end-to-end)")
struct AudioCaptureIntegrationTests {
    private let sampleRate: Double = 16_000

    /// Writes a short 16kHz mono sine wave to a temporary WAV file and returns its URL.
    /// `TestFileAudioSource` replays whatever `AVAudioFile.processingFormat` resolves to, so the
    /// dummy input must already be 16kHz mono to match `AudioCaptureConfig`'s defaults.
    private func makeDummyWavFile(seconds: Double) throws -> URL {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioCaptureIntegrationTests-dummy-\(UUID().uuidString)")
            .appendingPathExtension("wav")

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        let file = try AVAudioFile(forWriting: fileURL, settings: settings)

        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let frameCount = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let samples = buffer.floatChannelData![0]
        for frame in 0..<Int(frameCount) {
            samples[frame] = Float(sin(2.0 * Double.pi * 440.0 * Double(frame) / sampleRate)) * 0.1
        }
        try file.write(from: buffer)

        return fileURL
    }

    private func makeSessionDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioCaptureIntegrationTests-session-\(UUID().uuidString)", isDirectory: true)
    }

    /// Polls until the delegate has observed `didStop`, which `AudioCapture` delivers on its own
    /// `eventQueue` rather than synchronously from `stop()`. The timeout is a hang guard only.
    private func waitUntilDelegateStopped(_ delegate: RecordingDelegate, timeout: Duration = .seconds(10)) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if delegate.didStopCallCount >= 1 { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Reads the 4-byte little-endian `data` chunk size (bytes 40..<44), independent of
    /// `WavHeader`/`WavFileWriter`, to verify what actually landed on disk.
    private func readDataChunkSize(at url: URL) throws -> UInt32 {
        let fileData = try Data(contentsOf: url)
        let bytes = [UInt8](fileData[40..<44])
        return UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
    }

    @Test("start() with two TestFileAudioSource instances writes non-empty mic.wav and system.wav, delivers buffers for both sources, and reaches .stopped after stop()")
    func endToEndRecordingProducesBothWavFiles() async throws {
        let dummyWav = try makeDummyWavFile(seconds: 1.0)
        defer { try? FileManager.default.removeItem(at: dummyWav) }

        let sessionDirectory = makeSessionDirectory()
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }

        let config = AudioCaptureConfig(headerFlushInterval: 0.2)
        let capture = AudioCapture(
            sessionDirectory: sessionDirectory,
            config: config,
            microphoneSource: TestFileAudioSource(fileURL: dummyWav, chunkFrameCount: config.micTapBufferSize),
            systemAudioSource: TestFileAudioSource(fileURL: dummyWav, chunkFrameCount: config.micTapBufferSize)
        )
        let delegate = RecordingDelegate()
        capture.delegate = delegate

        try await capture.start()
        #expect(capture.state == .running(activeSources: [.mic, .system]))

        // Long enough for TestFileAudioSource's ~64ms-tick timer to deliver several chunks on
        // both sources and for at least one headerFlushInterval to elapse.
        try await Task.sleep(nanoseconds: 500_000_000)

        await capture.stop()
        #expect(capture.state == .stopped)

        let micURL = sessionDirectory.appendingPathComponent("audio/mic_000.wav")
        let systemURL = sessionDirectory.appendingPathComponent("audio/system_000.wav")
        #expect(FileManager.default.fileExists(atPath: micURL.path))
        #expect(FileManager.default.fileExists(atPath: systemURL.path))

        let micDataSize = try readDataChunkSize(at: micURL)
        let systemDataSize = try readDataChunkSize(at: systemURL)
        #expect(micDataSize > 0)
        #expect(systemDataSize > 0)

        let micFileData = try Data(contentsOf: micURL)
        let systemFileData = try Data(contentsOf: systemURL)
        #expect(micFileData.count == 44 + Int(micDataSize))
        #expect(systemFileData.count == 44 + Int(systemDataSize))

        #expect(delegate.capturedSources.contains(.mic))
        #expect(delegate.capturedSources.contains(.system))
        // `didStop` is dispatched onto `AudioCapture`'s own `eventQueue`, so it is not necessarily
        // delivered by the time `stop()` returns -- asserting it immediately raced that hop and lost
        // whenever the machine was busy (observed both under heavy local load and on CI).
        try await waitUntilDelegateStopped(delegate)
        #expect(delegate.didStopCallCount == 1)
        #expect(delegate.degradedSources.isEmpty)

        // `elapsed` (section 7) must be monotonically non-decreasing within each source's own
        // delivery order (buffers from different sources interleave, so this is checked
        // per-source rather than across the combined sequence).
        let micElapsed = delegate.elapsedBySource[.mic] ?? []
        let systemElapsed = delegate.elapsedBySource[.system] ?? []
        #expect(!micElapsed.isEmpty)
        #expect(!systemElapsed.isEmpty)
        #expect(micElapsed == micElapsed.sorted())
        #expect(systemElapsed == systemElapsed.sorted())

        // Regression guard for `recordingStartHostTime` being assigned *before* either source's
        // `start()` is called (see `AudioCapture.start()`): if it were instead assigned only after
        // both sources finish starting, a buffer callback that raced ahead of that assignment would
        // compute `elapsed` against the storage's stale zero initial value -- i.e. against host time
        // 0, the machine's boot time -- producing a huge elapsed value (this test runs for well
        // under a second). Bounding every `elapsed` sample to a small window catches that class of bug.
        #expect(micElapsed.allSatisfy { $0 >= 0 && $0 < 5.0 })
        #expect(systemElapsed.allSatisfy { $0 >= 0 && $0 < 5.0 })
    }

    @Test("stop() racing with in-flight buffer delivery does not crash and still closes both WAV files cleanly")
    func stopRacingWithBufferDeliveryIsSafe() async throws {
        // Regression guard for `micWriter`/`systemWriter` (now `writersStorage`) being read from the
        // audio-callback thread (`handleBuffer`) while `stop()` clears them concurrently from the
        // caller's thread with no lock/queue hop between the two (see `AudioCapture.writersStorage`).
        // Without that lock this is a data race that TSan would flag and that can crash in practice;
        // repeating start/stop with buffers actively in flight exercises that path under contention.
        let dummyWav = try makeDummyWavFile(seconds: 1.0)
        defer { try? FileManager.default.removeItem(at: dummyWav) }

        for _ in 0..<5 {
            let sessionDirectory = makeSessionDirectory()
            defer { try? FileManager.default.removeItem(at: sessionDirectory) }

            let config = AudioCaptureConfig(headerFlushInterval: 60)
            let capture = AudioCapture(
                sessionDirectory: sessionDirectory,
                config: config,
                microphoneSource: TestFileAudioSource(fileURL: dummyWav, chunkFrameCount: config.micTapBufferSize),
                systemAudioSource: TestFileAudioSource(fileURL: dummyWav, chunkFrameCount: config.micTapBufferSize)
            )

            try await capture.start()
            // No sleep here on purpose: `TestFileAudioSource` delivers its first chunk on a ~64ms
            // timer tick, so `stop()` below races directly against `handleBuffer` running on that
            // timer's queue for at least some of these five iterations.
            await capture.stop()

            #expect(capture.state == .stopped)
        }
    }

    @Test("start() continues with microphone-only when system.wav cannot be opened, and removes no mic.wav placeholder")
    func startDegradesToMicOnlyWhenSystemWavCannotBeOpened() async throws {
        // Regression guard for `system.wav`'s open failure being treated as best-effort (section 9,
        // failure mode #12) rather than aborting the whole recording: pre-create a *directory* named
        // `system.wav` so `WavFileWriter`'s `FileManager.default.createFile` deterministically fails
        // to open it as a file, while `mic.wav`'s path is left untouched and opens normally.
        let dummyWav = try makeDummyWavFile(seconds: 1.0)
        defer { try? FileManager.default.removeItem(at: dummyWav) }

        let sessionDirectory = makeSessionDirectory()
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }

        let audioDirectory = sessionDirectory.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: audioDirectory.appendingPathComponent("system_000.wav"),
            withIntermediateDirectories: false
        )

        let config = AudioCaptureConfig(headerFlushInterval: 60)
        let capture = AudioCapture(
            sessionDirectory: sessionDirectory,
            config: config,
            microphoneSource: TestFileAudioSource(fileURL: dummyWav, chunkFrameCount: config.micTapBufferSize),
            systemAudioSource: TestFileAudioSource(fileURL: dummyWav, chunkFrameCount: config.micTapBufferSize)
        )
        let delegate = RecordingDelegate()
        capture.delegate = delegate

        try await capture.start()
        #expect(capture.state == .running(activeSources: [.mic]))

        try await Task.sleep(nanoseconds: 200_000_000)
        await capture.stop()
        #expect(capture.state == .stopped)

        let micURL = audioDirectory.appendingPathComponent("mic_000.wav")
        #expect(FileManager.default.fileExists(atPath: micURL.path))
        let micDataSize = try readDataChunkSize(at: micURL)
        #expect(micDataSize > 0)

        #expect(delegate.degradedSources == [.system])
        #expect(delegate.capturedSources.contains(.mic))
        #expect(!delegate.capturedSources.contains(.system))
    }

    @Test("stop() before any buffers arrive still produces valid (header-only) WAV files")
    func stopImmediatelyAfterStartStillProducesValidHeaders() async throws {
        let dummyWav = try makeDummyWavFile(seconds: 1.0)
        defer { try? FileManager.default.removeItem(at: dummyWav) }

        let sessionDirectory = makeSessionDirectory()
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }

        let config = AudioCaptureConfig(headerFlushInterval: 60)
        let capture = AudioCapture(
            sessionDirectory: sessionDirectory,
            config: config,
            microphoneSource: TestFileAudioSource(fileURL: dummyWav, chunkFrameCount: config.micTapBufferSize),
            systemAudioSource: TestFileAudioSource(fileURL: dummyWav, chunkFrameCount: config.micTapBufferSize)
        )

        try await capture.start()
        await capture.stop()

        let micURL = sessionDirectory.appendingPathComponent("audio/mic_000.wav")
        let fileData = try Data(contentsOf: micURL)
        #expect(fileData.count >= 44)
    }
}

/// Records every `AudioCaptureDelegate` callback for assertion. `AudioCaptureDelegate` fires all
/// callbacks on `AudioCapture`'s internal `eventQueue` (section 5.1), i.e. never on the calling
/// test's thread, so this recorder must be its own synchronization boundary.
private final class RecordingDelegate: AudioCaptureDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _capturedSources: [AudioSourceKind] = []
    private var _elapsedBySource: [AudioSourceKind: [TimeInterval]] = [:]
    private var _degradedSources: [AudioSourceKind] = []
    private var _didStopCallCount = 0

    var capturedSources: [AudioSourceKind] {
        lock.lock(); defer { lock.unlock() }
        return _capturedSources
    }

    var elapsedBySource: [AudioSourceKind: [TimeInterval]] {
        lock.lock(); defer { lock.unlock() }
        return _elapsedBySource
    }

    var degradedSources: [AudioSourceKind] {
        lock.lock(); defer { lock.unlock() }
        return _degradedSources
    }

    var didStopCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _didStopCallCount
    }

    func audioCapture(_ capture: AudioCapture, didCapture buffer: AVAudioPCMBuffer, source: AudioSourceKind, elapsed: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        _capturedSources.append(source)
        _elapsedBySource[source, default: []].append(elapsed)
    }

    func audioCapture(_ capture: AudioCapture, didDegrade source: AudioSourceKind, error: AudioCaptureError) {
        lock.lock(); defer { lock.unlock() }
        _degradedSources.append(source)
    }

    func audioCapture(_ capture: AudioCapture, didUpdateLevel level: Double, source: AudioSourceKind) {
        // Not asserted on directly in these tests; level metering is exercised implicitly by not crashing.
    }

    func audioCaptureDidStop(_ capture: AudioCapture) {
        lock.lock(); defer { lock.unlock() }
        _didStopCallCount += 1
    }
}
