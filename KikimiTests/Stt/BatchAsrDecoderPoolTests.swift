import FluidAudio
import Foundation
import Testing

@testable import Kikimi

/// Unit tests for `BatchAsrDecoderPool` (`Kikimi/Stt/BatchAsrDecoder.swift`,
/// `docs/design/33-meeting-two-pass-decode.md` MT7/MT8, section 7 layer 1). Every test constructs
/// its own `BatchAsrDecoderPool` instance with an injected `load` closure (never `.shared`) so
/// suites can run in parallel without sharing process-global state, and the injected loader never
/// touches FluidAudio's network path or a real model -- it just wraps a fresh, model-less
/// `AsrManager` so the returned `BatchAsrDecoder` is a distinct, identifiable instance.
@Suite("BatchAsrDecoderPool")
struct BatchAsrDecoderPoolTests {
    // MARK: - Test doubles

    /// A `BatchAsrDecoder` cheap enough to build in a unit test: `AsrManager(models: nil)` never
    /// loads a real CoreML model or touches the network, it just constructs an actor with `nil`
    /// model properties. Pool tests never call `.transcribe()` on the result, only compare
    /// identity, so this is a faithful-enough stand-in for "a warm decoder".
    private static func makeFakeDecoder() -> BatchAsrDecoder {
        BatchAsrDecoder(manager: AsrManager(models: nil), decoderLayers: 2)
    }

    /// Records how many times `load` was actually invoked (i.e. how many times the pool did *not*
    /// join an in-flight or already-cached decoder), `@unchecked Sendable` box guarded by `NSLock`
    /// (mirrors `DictationControllerTwoPassTests`' `OSAllocatedUnfairLockBox`).
    private final class CallCounter: @unchecked Sendable {
        private var count = 0
        private let lock = NSLock()

        func increment() -> Int {
            lock.lock()
            defer { lock.unlock() }
            count += 1
            return count
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    /// A one-shot async gate a test can hold `load` on until it explicitly wants the load to
    /// "complete" -- lets tests deterministically interleave multiple `acquire` calls (single-flight
    /// joins, cancellation before completion) without relying on timing.
    private actor LoadGate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        func open() {
            guard !isOpen else { return }
            isOpen = true
            let pending = waiters
            waiters = []
            for continuation in pending {
                continuation.resume()
            }
        }
    }

    private func makePool(
        counter: CallCounter,
        gate: LoadGate? = nil
    ) -> BatchAsrDecoderPool {
        BatchAsrDecoderPool(load: { _ in
            _ = counter.increment()
            await gate?.wait()
            return Self.makeFakeDecoder()
        })
    }

    /// `BatchAsrDecoderLease.release()` is synchronous and reaches the pool actor through a
    /// fire-and-forget `Task` (see `BatchAsrDecoderPool.refcountForTesting`'s doc comment), so a
    /// test that calls `release()` and immediately re-`acquire`s can race the decrement. Polling
    /// `refcountForTesting` first waits for that hop to actually land.
    private func waitUntilRefcount(
        _ pool: BatchAsrDecoderPool,
        version: AsrModelVersion,
        equals expected: Int,
        timeout: Duration = .seconds(2)
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await pool.refcountForTesting(version: version) == expected { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        let finalValue = await pool.refcountForTesting(version: version)
        #expect(finalValue == expected, "refcount did not settle to \(expected) within \(timeout)")
    }

    // MARK: - Refcount

    @Test("two acquires survive one release; the second release frees the decoder")
    func refcountSurvivesUntilBalancedReleases() async throws {
        let counter = CallCounter()
        let pool = makePool(counter: counter)

        let lease1 = try await pool.acquire(version: .tdtJa)
        let lease2 = try await pool.acquire(version: .tdtJa)
        #expect(counter.value == 1, "the second acquire should join the already-warm decoder, not reload")

        lease1.release()
        try await waitUntilRefcount(pool, version: .tdtJa, equals: 1)
        // Still one outstanding lease (lease2): a fresh acquire must reuse the cached decoder.
        let lease3 = try await pool.acquire(version: .tdtJa)
        #expect(counter.value == 1, "refcount > 0 after the first release -- no reload expected")
        lease3.release()
        try await waitUntilRefcount(pool, version: .tdtJa, equals: 1)

        lease2.release()
        try await waitUntilRefcount(pool, version: .tdtJa, equals: 0)
        // Refcount is now 0: the decoder must have been freed, so a new acquire reloads.
        _ = try await pool.acquire(version: .tdtJa)
        #expect(counter.value == 2, "refcount reaching 0 must free the decoder so the next acquire reloads")
    }

    // MARK: - Single-flight

    @Test("concurrent acquires for the same version single-flight to exactly one load")
    func concurrentAcquiresSingleFlight() async throws {
        let counter = CallCounter()
        let gate = LoadGate()
        let pool = makePool(counter: counter, gate: gate)

        async let first = pool.acquire(version: .tdtJa)
        async let second = pool.acquire(version: .tdtJa)
        async let third = pool.acquire(version: .tdtJa)

        // Give the three calls a chance to all reach the (gated) load before opening it, so all
        // three observably join the same in-flight load rather than racing ahead of each other.
        try await Task.sleep(for: .milliseconds(50))
        await gate.open()

        let leases = try await [first, second, third]
        #expect(counter.value == 1, "only the first holder should have started the load; the rest joined it")

        for lease in leases {
            lease.release()
        }
    }

    // MARK: - Cancellation before load completes

    @Test("cancelling the acquiring task before the load completes returns the refcount, leaking nothing")
    func cancellationBeforeLoadCompletesLeaksNoRefcount() async throws {
        let counter = CallCounter()
        let gate = LoadGate()
        let pool = makePool(counter: counter, gate: gate)

        let acquireTask = Task { try await pool.acquire(version: .tdtJa) }
        try await Task.sleep(for: .milliseconds(50))
        acquireTask.cancel()
        await gate.open()

        await #expect(throws: CancellationError.self) {
            _ = try await acquireTask.value
        }

        // The cancelled acquire was the sole holder, so its rollback must have dropped the
        // refcount to 0 and freed the (successfully but unwantedly loaded) decoder -- a fresh
        // acquire must reload rather than reuse it.
        let lease = try await pool.acquire(version: .tdtJa)
        #expect(counter.value == 2, "a cancelled sole holder must not leave a refcount behind")
        lease.release()
    }

    // MARK: - Load failure

    private struct LoadFailure: Error {}

    /// `@unchecked Sendable` toggle box guarded by `NSLock` (mirrors `CallCounter` above) so the
    /// injected `load` closure can flip from "always fail" to "succeed" partway through the test
    /// without tripping Swift 6's captured-var-in-a-Sendable-closure diagnostic.
    private final class FailureSwitch: @unchecked Sendable {
        private var shouldFail: Bool
        private let lock = NSLock()

        init(shouldFail: Bool) {
            self.shouldFail = shouldFail
        }

        var isFailing: Bool {
            lock.lock()
            defer { lock.unlock() }
            return shouldFail
        }

        func stopFailing() {
            lock.lock()
            defer { lock.unlock() }
            shouldFail = false
        }
    }

    @Test("a load failure rolls back the refcount so a later acquire retries rather than reusing a broken entry")
    func loadFailureRollsBackRefcountAndAllowsRetry() async throws {
        let counter = CallCounter()
        let failureSwitch = FailureSwitch(shouldFail: true)
        let pool = BatchAsrDecoderPool(load: { _ in
            _ = counter.increment()
            if failureSwitch.isFailing {
                throw LoadFailure()
            }
            return Self.makeFakeDecoder()
        })

        await #expect(throws: LoadFailure.self) {
            _ = try await pool.acquire(version: .tdtJa)
        }
        // The failed acquire was the sole holder, so its rollback must have dropped the refcount
        // back to 0 (MT8: "ロード失敗... はrefcountを戻してからthrow") -- nothing should be left
        // registered for a failed load to leak.
        #expect(await pool.refcountForTesting(version: .tdtJa) == 0)

        failureSwitch.stopFailing()
        let lease = try await pool.acquire(version: .tdtJa)
        #expect(counter.value == 2, "a prior load failure must not prevent a later acquire from retrying the load")
        lease.release()
    }

    // MARK: - Independent versions

    @Test("acquiring different AsrModelVersions maintains independent refcounts and decoders")
    func differentVersionsAreIndependent() async throws {
        let counter = CallCounter()
        let pool = makePool(counter: counter)

        let jaLease = try await pool.acquire(version: .tdtJa)
        let v3Lease = try await pool.acquire(version: .v3)
        #expect(counter.value == 2, "different versions must never join each other's load or cache")
        #expect(jaLease.decoder !== v3Lease.decoder)

        // Releasing one version's sole lease must free only that version's entry, leaving the
        // other version's refcount and cached decoder untouched.
        jaLease.release()
        try await waitUntilRefcount(pool, version: .tdtJa, equals: 0)
        #expect(await pool.refcountForTesting(version: .v3) == 1, "releasing .tdtJa must not affect .v3's refcount")

        let joiningV3Lease = try await pool.acquire(version: .v3)
        #expect(counter.value == 2, ".v3 acquire must join the still-warm .v3 decoder, not reload")
        #expect(joiningV3Lease.decoder === v3Lease.decoder)

        v3Lease.release()
        joiningV3Lease.release()
        try await waitUntilRefcount(pool, version: .v3, equals: 0)
    }

    // MARK: - Idempotent release

    @Test("releasing a lease twice is a no-op the second time")
    func doubleReleaseIsNoOp() async throws {
        let counter = CallCounter()
        let pool = makePool(counter: counter)

        let lease1 = try await pool.acquire(version: .tdtJa)
        let lease2 = try await pool.acquire(version: .tdtJa)
        #expect(counter.value == 1)

        lease1.release()
        try await waitUntilRefcount(pool, version: .tdtJa, equals: 1)
        lease1.release() // must not decrement a second time
        // No actor hop to wait for here (idempotent release short-circuits before touching the
        // pool at all), but give any accidental second hop a moment to land before asserting.
        try await Task.sleep(for: .milliseconds(20))

        // lease2 is still outstanding, and lease1's double release must have only cost one
        // decrement -- the cached decoder must still be there for a fresh acquire to join.
        let lease3 = try await pool.acquire(version: .tdtJa)
        #expect(counter.value == 1, "a double release must not over-decrement the refcount")

        lease2.release()
        lease3.release()
    }

    // MARK: - Independent leases

    @Test("releasing one lease does not release another lease held concurrently for the same version")
    func releasingOneLeaseDoesNotAffectAnother() async throws {
        let counter = CallCounter()
        let pool = makePool(counter: counter)

        // Simulates the meeting pipeline and dictation both holding a lease on the same
        // AsrModelVersion (design 33 MT7's ja/ja shared-decoder case).
        let meetingLease = try await pool.acquire(version: .tdtJa)
        let dictationLease = try await pool.acquire(version: .tdtJa)
        #expect(counter.value == 1)

        meetingLease.release()
        try await waitUntilRefcount(pool, version: .tdtJa, equals: 1)

        // dictation's lease must still be backed by the same warm decoder -- unaffected by the
        // meeting side's release.
        #expect(dictationLease.decoder === meetingLease.decoder)
        let joiningLease = try await pool.acquire(version: .tdtJa)
        #expect(counter.value == 1, "the meeting's release must not have freed dictation's decoder")

        dictationLease.release()
        joiningLease.release()
        try await waitUntilRefcount(pool, version: .tdtJa, equals: 0)

        // Now every holder has released: the decoder must be gone.
        let freshLease = try await pool.acquire(version: .tdtJa)
        #expect(counter.value == 2, "once every lease is released the decoder must be freed")
        freshLease.release()
    }
}
