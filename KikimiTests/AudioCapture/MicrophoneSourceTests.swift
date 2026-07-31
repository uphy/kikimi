import AVFoundation
import Foundation
import Testing

@testable import Kikimi

/// Covers the `AVAudioEngine.configurationChangeNotification` reconfiguration path added to
/// `MicrophoneSource` (`docs/design/10-audio-input-selection.md` section 8, failure mode #9): a
/// mid-recording system-default-input switch (Sound settings, AirPods connecting, etc.) no longer
/// leaves `inputNode` bound to the device that was active at the last `engine.start()`.
///
/// These tests deliberately never call `MicrophoneSource.start(bufferHandler:)`: it calls through
/// to `checkPermission()`, which can synchronously block on the system microphone-permission
/// prompt (or crash a process with no `NSMicrophoneUsageDescription`) -- unsafe to run inside a
/// test process, exactly like `DictationAudioInputTests`'s documented reason for the same
/// avoidance. Instead they drive `MicrophoneSource`'s `internal` "Testable seams"
/// (`markStartedForTesting`/`triggerConfigurationChangeForTesting`/`testReconfigureFormatOverride`)
/// directly, combined with `FakeAVAudioEngine` (a real `AVAudioEngine` subclass that only
/// overrides `start()`, so nothing here ever touches TCC or an actual capture session).
@Suite("MicrophoneSource configuration-change reconfiguration")
struct MicrophoneSourceTests {
    /// A real `AVAudioEngine` whose `start()` is fully test-controlled (never calls `super`, so no
    /// real audio I/O ever begins) -- every other member (`inputNode`, `stop()`, tap
    /// install/remove) is the genuine `AVAudioEngine` implementation, which is safe to exercise
    /// without microphone permission (format queries and tap registration do not themselves start
    /// capturing).
    private final class FakeAVAudioEngine: AVAudioEngine {
        private(set) var startCallCount = 0
        var startError: Error?

        override func start() throws {
            startCallCount += 1
            if let startError {
                throw startError
            }
        }
    }

    private struct StubError: Error {}

    /// Constructs a genuinely invalid `AVAudioFormat` (zero sample rate/channel count) the same
    /// way `MicrophoneSource`'s own guard checks for -- `AVAudioEngine.inputNode.inputFormat`
    /// returns exactly this shape when there are zero input devices (section 5.1's existing
    /// guard), which is not reproducible on demand against a real device, hence constructing it
    /// directly here via `testReconfigureFormatOverride`.
    private func invalidFormat() -> AVAudioFormat {
        var asbd = AudioStreamBasicDescription()
        asbd.mSampleRate = 0
        asbd.mChannelsPerFrame = 0
        asbd.mFormatID = kAudioFormatLinearPCM
        asbd.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        asbd.mBitsPerChannel = 32
        asbd.mBytesPerFrame = 4
        asbd.mBytesPerPacket = 4
        asbd.mFramesPerPacket = 1
        return AVAudioFormat(streamDescription: &asbd)!
    }

    @Test("a configuration-change notification arriving before start() (or after stop()) is a no-op")
    func reconfigureNoOpWhenNotRunning() {
        let engine = FakeAVAudioEngine()
        let source = MicrophoneSource(engine: engine)

        source.triggerConfigurationChangeForTesting()

        #expect(source.isRunningForTesting == false)
        #expect(source.converterIdentityForTesting == nil)
        #expect(engine.startCallCount == 0)
    }

    // The "success" tests below deliberately never set `testReconfigureFormatOverride`: the real
    // `AVAudioNode.installTap` validates its `format:` argument against the node's actual
    // (hardware-derived) output format and crashes on a mismatch, so only `nil` (falling through
    // to the real `inputNode.inputFormat(forBus: 0)` query, which every macOS test-runner machine
    // reports *some* valid non-zero format for even without microphone permission -- format
    // queries alone do not require TCC) is safe to combine with an actual `installTap` call.
    // `testReconfigureFormatOverride` is only used below for the invalid-format test, whose branch
    // returns before ever reaching `installTap`.

    @Test("a valid post-change format rebuilds the converter, restarts the engine, and keeps capturing")
    func reconfigureSuccessRebuildsConverterAndRestartsEngine() {
        let engine = FakeAVAudioEngine()
        let source = MicrophoneSource(engine: engine)
        source.markStartedForTesting { _, _ in }
        #expect(source.converterIdentityForTesting == nil) // nothing rebuilt yet

        source.triggerConfigurationChangeForTesting()

        #expect(source.isRunningForTesting == true)
        #expect(source.converterIdentityForTesting != nil)
        #expect(engine.startCallCount == 1)
    }

    @Test("reconfiguring twice rebuilds a distinct converter each time")
    func reconfigureTwiceRebuildsConverterEachTime() {
        let engine = FakeAVAudioEngine()
        let source = MicrophoneSource(engine: engine)
        source.markStartedForTesting { _, _ in }

        source.triggerConfigurationChangeForTesting()
        let firstConverterIdentity = source.converterIdentityForTesting

        source.triggerConfigurationChangeForTesting()
        let secondConverterIdentity = source.converterIdentityForTesting

        #expect(firstConverterIdentity != nil)
        #expect(secondConverterIdentity != nil)
        #expect(firstConverterIdentity != secondConverterIdentity)
        #expect(source.isRunningForTesting == true)
        #expect(engine.startCallCount == 2)
    }

    @Test("an invalid post-change format (e.g. zero input devices) stops capture instead of crashing")
    func reconfigureInvalidFormatStopsCapture() {
        let engine = FakeAVAudioEngine()
        let source = MicrophoneSource(engine: engine)
        source.markStartedForTesting { _, _ in }

        source.testReconfigureFormatOverride = invalidFormat()
        source.triggerConfigurationChangeForTesting()

        #expect(source.isRunningForTesting == false)
        #expect(source.converterIdentityForTesting == nil)
        // The invalid-format guard trips before ever reaching `engine.start()` again.
        #expect(engine.startCallCount == 0)
    }

    @Test("an engine restart failure after a device change stops capture instead of retrying forever")
    func reconfigureEngineRestartFailureStopsCapture() {
        let engine = FakeAVAudioEngine()
        engine.startError = StubError()
        let source = MicrophoneSource(engine: engine)
        source.markStartedForTesting { _, _ in }

        source.triggerConfigurationChangeForTesting()

        #expect(source.isRunningForTesting == false)
        #expect(source.converterIdentityForTesting == nil)
        #expect(engine.startCallCount == 1)

        // A second notification must not retry indefinitely: the observer was torn down alongside
        // `isRunning`, so a manual re-trigger (simulating a notification that was already in
        // flight) stays a no-op rather than attempting another restart.
        source.triggerConfigurationChangeForTesting()
        #expect(engine.startCallCount == 1)
    }
}
