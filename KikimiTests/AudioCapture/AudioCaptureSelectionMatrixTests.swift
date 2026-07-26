import AVFoundation
import Foundation
import Testing

@testable import Kikimi

/// Layer 1 (unit) coverage for `AudioCapture.start()`'s selection-driven matrix
/// (`docs/design/10-audio-input-selection.md` section 5.2), using fake `AudioSourceCapturing`
/// collaborators so no real hardware/permissions are touched. Complements
/// `AudioCaptureIntegrationTests` (which exercises the pre-existing both-enabled path end-to-end
/// with `TestFileAudioSource`) by covering the disabled-source rows this design adds.
@Suite("AudioCapture selection matrix (start() with AudioInputSelection)")
struct AudioCaptureSelectionMatrixTests {
    private func makeSessionDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioCaptureSelectionMatrixTests-session-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("mic enabled / system disabled: the disabled system source's start() is never called and system.wav is not created")
    func disabledSystemSourceIsNeverStarted() async throws {
        let sessionDirectory = makeSessionDirectory()
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }

        let fakeMic = FakeAudioSourceCapturing()
        let fakeSystem = FakeAudioSourceCapturing()

        let selection = AudioInputSelection(
            mic: MicSelection(enabled: true, deviceUid: nil),
            system: SystemAudioSelection(enabled: false, bundleId: nil)
        )
        let capture = AudioCapture(
            sessionDirectory: sessionDirectory,
            selection: selection,
            microphoneSource: fakeMic,
            systemAudioSource: fakeSystem
        )

        try await capture.start()
        #expect(capture.state == .running(activeSources: [.mic]))

        #expect(fakeMic.startCallCount == 1)
        #expect(fakeSystem.startCallCount == 0)

        await capture.stop()

        let micURL = sessionDirectory.appendingPathComponent("audio/mic_000.wav")
        let systemURL = sessionDirectory.appendingPathComponent("audio/system_000.wav")
        #expect(FileManager.default.fileExists(atPath: micURL.path))
        #expect(!FileManager.default.fileExists(atPath: systemURL.path))
    }

    @Test("mic disabled / system enabled: mic.wav is not created and the disabled mic source's start() is never called")
    func disabledMicSourceProducesNoMicWav() async throws {
        let sessionDirectory = makeSessionDirectory()
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }

        let fakeMic = FakeAudioSourceCapturing()
        let fakeSystem = FakeAudioSourceCapturing()

        let selection = AudioInputSelection(
            mic: MicSelection(enabled: false, deviceUid: nil),
            system: SystemAudioSelection(enabled: true, bundleId: nil)
        )
        let capture = AudioCapture(
            sessionDirectory: sessionDirectory,
            selection: selection,
            microphoneSource: fakeMic,
            systemAudioSource: fakeSystem
        )

        try await capture.start()
        #expect(capture.state == .running(activeSources: [.system]))

        #expect(fakeMic.startCallCount == 0)
        #expect(fakeSystem.startCallCount == 1)

        await capture.stop()

        let micURL = sessionDirectory.appendingPathComponent("audio/mic_000.wav")
        let systemURL = sessionDirectory.appendingPathComponent("audio/system_000.wav")
        #expect(!FileManager.default.fileExists(atPath: micURL.path))
        #expect(FileManager.default.fileExists(atPath: systemURL.path))
    }

    @Test("mic disabled / system enabled: a system start() failure is fatal (.systemAudioStartFailed), not a mic-only degrade")
    func systemOnlyStartFailureIsFatal() async throws {
        let sessionDirectory = makeSessionDirectory()
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }

        let fakeSystem = FakeAudioSourceCapturing()
        fakeSystem.startError = FakeSourceError()

        let selection = AudioInputSelection(
            mic: MicSelection(enabled: false, deviceUid: nil),
            system: SystemAudioSelection(enabled: true, bundleId: nil)
        )
        let capture = AudioCapture(
            sessionDirectory: sessionDirectory,
            selection: selection,
            microphoneSource: FakeAudioSourceCapturing(),
            systemAudioSource: fakeSystem
        )

        await #expect(throws: AudioCaptureError.self) {
            try await capture.start()
        }
        #expect(capture.state == .idle)

        // The fatal path removes any placeholder WAV files it opened along the way (section 5,
        // mirrors the pre-existing "no empty file left behind" cleanup for the mic-fatal path).
        let systemURL = sessionDirectory.appendingPathComponent("audio/system_000.wav")
        #expect(!FileManager.default.fileExists(atPath: systemURL.path))
    }

    @Test("both enabled: a system-only start() failure still degrades to mic-only, matching the pre-existing (pre-selection) behavior")
    func bothEnabledSystemFailureStillDegradesToMicOnly() async throws {
        let sessionDirectory = makeSessionDirectory()
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }

        let fakeMic = FakeAudioSourceCapturing()
        let fakeSystem = FakeAudioSourceCapturing()
        fakeSystem.startError = FakeSourceError()

        let delegate = RecordingDegradeDelegate()
        let capture = AudioCapture(
            sessionDirectory: sessionDirectory,
            selection: .default,
            microphoneSource: fakeMic,
            systemAudioSource: fakeSystem
        )
        capture.delegate = delegate

        try await capture.start()
        #expect(capture.state == .running(activeSources: [.mic]))
        #expect(fakeMic.startCallCount == 1)
        #expect(fakeSystem.startCallCount == 1)

        // `didDegrade` is dispatched asynchronously onto `AudioCapture`'s internal `eventQueue`
        // (see `AudioCaptureDelegate`'s doc comment); poll briefly instead of assuming it has
        // already landed by the time `start()` returns.
        try await waitUntil { delegate.degradedSources.contains(.system) }
        #expect(delegate.degradedSources == [.system])

        await capture.stop()
    }
}

/// Polls `condition` until it becomes `true` or a short timeout elapses, for asserting on
/// `AudioCaptureDelegate` callbacks dispatched onto `AudioCapture`'s own `eventQueue`
/// asynchronously with respect to `start()` returning.
private func waitUntil(timeout: TimeInterval = 2.0, _ condition: @Sendable () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}

/// Fake `AudioSourceCapturing` that records `start()`/`stop()` call counts and can be configured
/// to fail `start()` with an arbitrary `Error`, without touching real hardware/permissions.
private final class FakeAudioSourceCapturing: AudioSourceCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private var _startCallCount = 0
    private var _stopCallCount = 0

    /// If set, `start(bufferHandler:)` throws this instead of succeeding. Read without the lock
    /// since it is only ever configured before `start()` is invoked by the test.
    var startError: Error?

    var startCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _startCallCount
    }

    var stopCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _stopCallCount
    }

    func start(bufferHandler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) throws {
        lock.lock()
        _startCallCount += 1
        lock.unlock()
        if let startError {
            throw startError
        }
    }

    func stop() {
        lock.lock()
        _stopCallCount += 1
        lock.unlock()
    }
}

private struct FakeSourceError: Error, Equatable {}

/// Thread-safe recorder for `AudioCaptureDelegate.audioCapture(_:didDegrade:error:)`, since that
/// callback fires on `AudioCapture`'s internal `eventQueue` rather than the test's own thread.
private final class RecordingDegradeDelegate: AudioCaptureDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _degradedSources: [AudioSourceKind] = []

    var degradedSources: [AudioSourceKind] {
        lock.lock(); defer { lock.unlock() }
        return _degradedSources
    }

    func audioCapture(_ capture: AudioCapture, didCapture buffer: AVAudioPCMBuffer, source: AudioSourceKind, elapsed: TimeInterval) {}

    func audioCapture(_ capture: AudioCapture, didDegrade source: AudioSourceKind, error: AudioCaptureError) {
        lock.lock()
        _degradedSources.append(source)
        lock.unlock()
    }

    func audioCapture(_ capture: AudioCapture, didUpdateLevel level: Double, source: AudioSourceKind) {}

    func audioCaptureDidStop(_ capture: AudioCapture) {}
}
