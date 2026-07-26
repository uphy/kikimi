import AVFoundation
import Foundation
import Testing

@testable import Kikimi

// MARK: - AudioSourceKind

@Suite("AudioSourceKind")
struct AudioSourceKindTests {
    @Test("raw values match the on-disk/JSON identifiers used for mic and system")
    func rawValues() {
        #expect(AudioSourceKind.mic.rawValue == "mic")
        #expect(AudioSourceKind.system.rawValue == "system")
    }

    @Test("round-trips through Codable using its raw string value")
    func codableRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for kind in [AudioSourceKind.mic, .system] {
            let data = try encoder.encode(kind)
            #expect(String(data: data, encoding: .utf8) == "\"\(kind.rawValue)\"")
            let decoded = try decoder.decode(AudioSourceKind.self, from: data)
            #expect(decoded == kind)
        }
    }
}

// MARK: - AudioCaptureConfig

@Suite("AudioCaptureConfig")
struct AudioCaptureConfigTests {
    @Test("default values match the documented Kikimi standard (16kHz mono, 1024-frame tap, 5s header flush)")
    func defaults() {
        let config = AudioCaptureConfig()

        #expect(config.sampleRate == 16_000)
        #expect(config.channels == 1)
        #expect(config.micTapBufferSize == 1_024)
        #expect(config.headerFlushInterval == 5.0)
    }

    @Test("two configs with identical fields are equal; differing fields are not")
    func equatable() {
        let a = AudioCaptureConfig()
        let b = AudioCaptureConfig()
        #expect(a == b)

        var c = AudioCaptureConfig()
        c.sampleRate = 44_100
        #expect(a != c)

        var d = AudioCaptureConfig()
        d.headerFlushInterval = 1.0
        #expect(a != d)
    }

    @Test("individual fields can be overridden independently of the defaults")
    func customValues() {
        var config = AudioCaptureConfig()
        config.sampleRate = 48_000
        config.channels = 2
        config.micTapBufferSize = 2_048
        config.headerFlushInterval = 10.0

        #expect(config.sampleRate == 48_000)
        #expect(config.channels == 2)
        #expect(config.micTapBufferSize == 2_048)
        #expect(config.headerFlushInterval == 10.0)
    }
}

// MARK: - AudioCaptureState

@Suite("AudioCaptureState")
struct AudioCaptureStateTests {
    @Test("idle, starting, stopping, and stopped are each equal only to themselves")
    func simpleCasesEquality() {
        #expect(AudioCaptureState.idle == .idle)
        #expect(AudioCaptureState.starting == .starting)
        #expect(AudioCaptureState.stopping == .stopping)
        #expect(AudioCaptureState.stopped == .stopped)

        #expect(AudioCaptureState.idle != .starting)
        #expect(AudioCaptureState.starting != .stopping)
        #expect(AudioCaptureState.stopping != .stopped)
        #expect(AudioCaptureState.stopped != .idle)
    }

    @Test("running(activeSources:) equality is based on the associated set contents, not identity")
    func runningEqualityBySetContents() {
        let bothA = AudioCaptureState.running(activeSources: [.mic, .system])
        let bothB = AudioCaptureState.running(activeSources: [.system, .mic])
        #expect(bothA == bothB)

        let micOnly = AudioCaptureState.running(activeSources: [.mic])
        #expect(bothA != micOnly)
    }

    @Test("running(activeSources:) is never equal to a differently-cased state, even with an empty set")
    func runningNotEqualToOtherCases() {
        let empty = AudioCaptureState.running(activeSources: [])
        #expect(empty != .idle)
        #expect(empty != .stopped)
    }

    @Test("degradation from {mic, system} to {mic} is representable as two distinct running states")
    func degradationIsRepresentedAsSetShrink() {
        let full = AudioCaptureState.running(activeSources: [.mic, .system])
        let degraded = AudioCaptureState.running(activeSources: [.mic])

        #expect(full != degraded)
        if case .running(let sources) = degraded {
            #expect(sources == [.mic])
        } else {
            Issue.record("expected .running case")
        }
    }
}

// MARK: - AudioCaptureError

@Suite("AudioCaptureError")
struct AudioCaptureErrorTests {
    @Test("errorDescription is non-empty and human-readable for every start()-time failure case")
    func startTimeFailureDescriptions() throws {
        let cases: [AudioCaptureError] = [
            .alreadyRunning,
            .sessionDirectoryUnavailable("disk full"),
            .microphonePermissionDenied,
            .microphonePermissionRestricted,
            .microphoneEngineFailed("engine start failed"),
            .allSourcesUnavailable
        ]

        for error in cases {
            let description = try #require(error.errorDescription)
            #expect(!description.isEmpty)
        }
    }

    @Test("errorDescription is non-empty and human-readable for every in-progress degradation case")
    func degradationDescriptions() throws {
        let cases: [AudioCaptureError] = [
            .systemAudioUnavailable(message: "tap unavailable"),
            .fileWriteFailed(source: .mic, message: "disk full")
        ]

        for error in cases {
            let description = try #require(error.errorDescription)
            #expect(!description.isEmpty)
        }
    }

    @Test("errorDescription interpolates the associated message/source values verbatim")
    func descriptionInterpolatesAssociatedValues() throws {
        let sessionError = AudioCaptureError.sessionDirectoryUnavailable("permission denied")
        #expect(try #require(sessionError.errorDescription).contains("permission denied"))

        let engineError = AudioCaptureError.microphoneEngineFailed("AVAudioEngine.start() threw")
        #expect(try #require(engineError.errorDescription).contains("AVAudioEngine.start() threw"))

        let systemAudioError = AudioCaptureError.systemAudioUnavailable(message: "no permission")
        #expect(try #require(systemAudioError.errorDescription).contains("no permission"))

        let fileWriteError = AudioCaptureError.fileWriteFailed(source: .mic, message: "ENOSPC")
        let fileWriteDescription = try #require(fileWriteError.errorDescription)
        #expect(fileWriteDescription.contains("mic"))
        #expect(fileWriteDescription.contains("ENOSPC"))
    }

    @Test("equatable distinguishes cases and associated values, including same case with different sources")
    func equatable() {
        #expect(AudioCaptureError.alreadyRunning == .alreadyRunning)
        #expect(AudioCaptureError.alreadyRunning != .allSourcesUnavailable)

        #expect(
            AudioCaptureError.sessionDirectoryUnavailable("a") == .sessionDirectoryUnavailable("a")
        )
        #expect(
            AudioCaptureError.sessionDirectoryUnavailable("a") != .sessionDirectoryUnavailable("b")
        )

        #expect(
            AudioCaptureError.fileWriteFailed(source: .mic, message: "x")
                == .fileWriteFailed(source: .mic, message: "x")
        )
        #expect(
            AudioCaptureError.fileWriteFailed(source: .mic, message: "x")
                != .fileWriteFailed(source: .system, message: "x")
        )
    }
}

// MARK: - AudioCaptureDelegate / AudioSourceCapturing conformance

@Suite("AudioCaptureDelegate and AudioSourceCapturing conformance")
struct AudioCaptureProtocolConformanceTests {
    @Test("a delegate implementation records all four callback kinds with their payloads")
    func delegateReceivesAllCallbacks() throws {
        let recorder = RecordingDelegate()
        let dummyCapture = DummyCaptureOwner()

        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 10))
        buffer.frameLength = 10

        recorder.audioCapture(dummyCapture, didCapture: buffer, source: .mic, elapsed: 1.5)
        recorder.audioCapture(dummyCapture, didDegrade: .system, error: .systemAudioUnavailable(message: "gone"))
        recorder.audioCapture(dummyCapture, didUpdateLevel: 0.75, source: .mic)
        recorder.audioCaptureDidStop(dummyCapture)

        #expect(recorder.capturedElapsed == [1.5])
        #expect(recorder.capturedSources == [.mic])
        #expect(recorder.degradedSources == [.system])
        #expect(recorder.levelUpdates == [0.75])
        #expect(recorder.didStopCallCount == 1)
    }

    @Test("a stub AudioSourceCapturing implementation delivers buffers via bufferHandler and stops cleanly")
    func sourceCapturingStubDeliversAndStops() throws {
        let stub = StubAudioSource()
        var delivered: [AVAudioFrameCount] = []

        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 100))
        buffer.frameLength = 100
        stub.bufferToDeliver = buffer

        try stub.start { buffer, _ in
            delivered.append(buffer.frameLength)
        }

        #expect(delivered == [100])
        #expect(stub.isRunning)

        stub.stop()
        #expect(!stub.isRunning)
    }
}

/// Minimal `AudioCapture`-shaped placeholder so delegate methods (which take an owning
/// `AudioCapture` reference) can be exercised without depending on the concrete class's
/// hardware-facing implementation.
private final class DummyCaptureOwner {}

/// Thread-unsafe (test-only, single-threaded) recorder verifying `AudioCaptureDelegate` callback shape.
private final class RecordingDelegate {
    private(set) var capturedElapsed: [TimeInterval] = []
    private(set) var capturedSources: [AudioSourceKind] = []
    private(set) var degradedSources: [AudioSourceKind] = []
    private(set) var levelUpdates: [Double] = []
    private(set) var didStopCallCount = 0

    func audioCapture(_ capture: DummyCaptureOwner, didCapture buffer: AVAudioPCMBuffer, source: AudioSourceKind, elapsed: TimeInterval) {
        capturedElapsed.append(elapsed)
        capturedSources.append(source)
    }

    func audioCapture(_ capture: DummyCaptureOwner, didDegrade source: AudioSourceKind, error: AudioCaptureError) {
        degradedSources.append(source)
    }

    func audioCapture(_ capture: DummyCaptureOwner, didUpdateLevel level: Double, source: AudioSourceKind) {
        levelUpdates.append(level)
    }

    func audioCaptureDidStop(_ capture: DummyCaptureOwner) {
        didStopCallCount += 1
    }
}

/// Minimal `AudioSourceCapturing` stub for verifying the protocol's DI contract in isolation.
private final class StubAudioSource: AudioSourceCapturing {
    var bufferToDeliver: AVAudioPCMBuffer?
    private(set) var isRunning = false

    func start(bufferHandler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) throws {
        isRunning = true
        if let buffer = bufferToDeliver {
            bufferHandler(buffer, AVAudioTime(hostTime: 0))
        }
    }

    func stop() {
        isRunning = false
    }
}
