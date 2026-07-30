import Foundation
import Testing

// MARK: - waitUntil

/// Polls `condition` until it holds, or fails the test on timeout.
///
/// **Use this instead of sleeping for a span assumed to contain the event.** A fixed sleep encodes an
/// assumption about how fast the machine is, and CI machines are not that fast: a runner sharing a few
/// cores with ~2,000 parallel tests delays a `DispatchSourceTimer`, a `Task`, and a serial queue's
/// next block by arbitrary amounts. Every such sleep is a test that fails for a reason unrelated to
/// the behaviour it describes.
///
/// The ceiling costs a passing test nothing, because the poll returns as soon as the condition holds
/// — so it can be generous. It exists only to turn a hang into a readable failure.
///
/// A **negative** claim ("this must *not* happen") is the one case where sleeping is legitimate: there
/// is no state to poll for, and a slow machine only makes the wait safer. Say so in a comment when
/// you do it, so the next reader does not "fix" it into a poll.
func waitUntil(
    timeout: Duration = .seconds(10),
    pollInterval: Duration = .milliseconds(10),
    _ description: @autoclosure () -> String = "condition to become true",
    sourceLocation: SourceLocation = #_sourceLocation,
    condition: () async -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: pollInterval)
    }
    Issue.record("Timed out after \(timeout) waiting for \(description())", sourceLocation: sourceLocation)
}
