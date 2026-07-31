import CoreAudio
import Foundation
import Testing

@testable import Kikimi

/// Layer 1 (unit) coverage for `SystemAudioSource.resolveExcludedProcesses(...)`'s pure
/// retry/give-up policy (`Kikimi/AudioCapture/SystemAudioSelfExclusion.swift`,
/// `docs/design/01-audio-capture.md` section 4 / section 9 failure mode #11). The real CoreAudio
/// calls it composes (`resolveSelfProcessObjectID`/`primeSelfHALRegistration`) are out of scope
/// for unit testing per the module brief -- `resolveSelf`/`primeSelfRegistration`/`sleep` are
/// injected fakes here instead.
@Suite("SystemAudioSource.resolveExcludedProcesses")
struct SystemAudioSelfExclusionTests {
    /// Records how many times each injected closure fired, so tests can assert on the exact
    /// retry/priming shape (not just the final returned list).
    private final class CallRecorder {
        var resolveSelfCallCount = 0
        var primeCallCount = 0
        var sleepCallCount = 0
        var onGiveUpCallCount = 0
    }

    @Test("returns Kikimi's own id plus additional excludes when resolution succeeds on the first try")
    func succeedsOnFirstAttempt() {
        let recorder = CallRecorder()
        let selfID = AudioObjectID(42)

        let result = SystemAudioSource.resolveExcludedProcesses(
            additionalExcludedProcesses: [AudioObjectID(7)],
            resolveSelf: {
                recorder.resolveSelfCallCount += 1
                return selfID
            },
            primeSelfRegistration: {
                recorder.primeCallCount += 1
                return nil
            },
            sleep: { _ in recorder.sleepCallCount += 1 },
            onGiveUp: { recorder.onGiveUpCallCount += 1 }
        )

        #expect(result.excluded == [AudioObjectID(7), selfID])
        #expect(result.primingToken == nil)
        #expect(recorder.resolveSelfCallCount == 1)
        #expect(recorder.primeCallCount == 0)
        #expect(recorder.sleepCallCount == 0)
        #expect(recorder.onGiveUpCallCount == 0)
    }

    @Test("primes HAL registration once and retries after the first attempt fails, succeeding on a later attempt")
    func primesAndRetriesUntilSuccess() {
        let recorder = CallRecorder()
        let selfID = AudioObjectID(99)
        // Fails the initial attempt and the first post-prime retry, succeeds on the second.
        let succeedsOnCall = 3
        // Stand-in for the production token that keeps the priming HAL client alive; the policy
        // must hand it back to the caller on success so the registration outlives resolution.
        let primingToken = NSObject()

        let result = SystemAudioSource.resolveExcludedProcesses(
            additionalExcludedProcesses: [],
            resolveSelf: {
                recorder.resolveSelfCallCount += 1
                return recorder.resolveSelfCallCount == succeedsOnCall ? selfID : nil
            },
            primeSelfRegistration: {
                recorder.primeCallCount += 1
                return primingToken
            },
            retryCount: 3,
            sleep: { _ in recorder.sleepCallCount += 1 },
            onGiveUp: { recorder.onGiveUpCallCount += 1 }
        )

        #expect(result.excluded == [selfID])
        #expect(result.primingToken as? NSObject === primingToken)
        #expect(recorder.resolveSelfCallCount == succeedsOnCall)
        #expect(recorder.primeCallCount == 1)
        // One sleep between the failed 1st and successful 2nd post-prime retry.
        #expect(recorder.sleepCallCount == 1)
        #expect(recorder.onGiveUpCallCount == 0)
    }

    @Test("gives up and returns the exclude list unchanged when every attempt fails")
    func givesUpAfterExhaustingRetries() {
        let recorder = CallRecorder()
        let retryCount = 3

        let result = SystemAudioSource.resolveExcludedProcesses(
            additionalExcludedProcesses: [AudioObjectID(11)],
            resolveSelf: {
                recorder.resolveSelfCallCount += 1
                return nil
            },
            primeSelfRegistration: {
                recorder.primeCallCount += 1
                return NSObject()
            },
            retryCount: retryCount,
            sleep: { _ in recorder.sleepCallCount += 1 },
            onGiveUp: { recorder.onGiveUpCallCount += 1 }
        )

        // Unchanged: the caller-supplied excludes survive even though self-resolution failed.
        #expect(result.excluded == [AudioObjectID(11)])
        // No exclude entry to keep valid on give-up, so the token is dropped rather than handed
        // back to the caller (returning it would keep a useless silent output stream running).
        #expect(result.primingToken == nil)
        // 1 initial attempt + retryCount post-prime attempts.
        #expect(recorder.resolveSelfCallCount == 1 + retryCount)
        #expect(recorder.primeCallCount == 1)
        // Sleeps only *between* retries, not after the last one.
        #expect(recorder.sleepCallCount == retryCount - 1)
        #expect(recorder.onGiveUpCallCount == 1)
    }

    @Test("default retryCount matches selfResolutionRetryCount")
    func defaultRetryCountMatchesConstant() {
        let recorder = CallRecorder()

        _ = SystemAudioSource.resolveExcludedProcesses(
            additionalExcludedProcesses: [],
            resolveSelf: {
                recorder.resolveSelfCallCount += 1
                return nil
            },
            primeSelfRegistration: { nil },
            sleep: { _ in },
            onGiveUp: {}
        )

        #expect(recorder.resolveSelfCallCount == 1 + SystemAudioSource.selfResolutionRetryCount)
    }
}
