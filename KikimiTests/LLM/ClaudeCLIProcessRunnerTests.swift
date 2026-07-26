import Foundation
import Testing

@testable import Kikimi

/// Layer 1 coverage for `ClaudeCLIProcessRunner` (`docs/design/12-llm-client.md` section 7):
/// path resolution is tested purely (no filesystem/process access at all), and the non-blocking
/// subprocess plumbing (`readabilityHandler` draining, timeout → SIGTERM → SIGKILL → reap) is
/// exercised against harmless system binaries (`/bin/echo`, `/bin/sh`, `/bin/sleep`) -- never the
/// real `claude` CLI, per this task's "実際に claude CLI を叩く統合テストは書かない" constraint,
/// which is specifically about not spending Claude Max subscription quota, not about avoiding
/// `Process` entirely.
@Suite("ClaudeCLIProcessRunner")
struct ClaudeCLIProcessRunnerTests {
    // MARK: - Path resolution (section 3.1), pure

    @Test("explicit override wins when it resolves as executable")
    func overrideWinsWhenExecutable() {
        let result = ClaudeCLIProcessRunner.resolveExecutablePath(
            override: "/custom/claude",
            whichResult: "/opt/homebrew/bin/claude",
            knownCandidates: ["/usr/local/bin/claude"],
            isExecutableFile: { path in ["/custom/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"].contains(path) }
        )
        #expect(result == .success("/custom/claude"))
    }

    @Test("falls back to the which(1) result when the override is not executable")
    func fallsBackToWhichResult() {
        let result = ClaudeCLIProcessRunner.resolveExecutablePath(
            override: "/custom/claude",
            whichResult: "/opt/homebrew/bin/claude",
            knownCandidates: ["/usr/local/bin/claude"],
            isExecutableFile: { path in ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"].contains(path) }
        )
        #expect(result == .success("/opt/homebrew/bin/claude"))
    }

    @Test("falls back to known candidates, in declared order, when override and which both fail")
    func fallsBackToKnownCandidatesInOrder() {
        let result = ClaudeCLIProcessRunner.resolveExecutablePath(
            override: "/custom/claude",
            whichResult: "/opt/homebrew/bin/claude",
            knownCandidates: ["/first/claude", "/second/claude"],
            isExecutableFile: { path in path == "/second/claude" }
        )
        #expect(result == .success("/second/claude"))
    }

    @Test("nil override/which skip straight to known candidates")
    func nilOverrideAndWhichSkipToKnownCandidates() {
        let result = ClaudeCLIProcessRunner.resolveExecutablePath(
            override: nil,
            whichResult: nil,
            knownCandidates: ["/only/claude"],
            isExecutableFile: { path in path == "/only/claude" }
        )
        #expect(result == .success("/only/claude"))
    }

    @Test("cliNotFound carries every searched path in priority order when nothing resolves")
    func cliNotFoundCarriesSearchedPathsInOrder() {
        let result = ClaudeCLIProcessRunner.resolveExecutablePath(
            override: "/custom/claude",
            whichResult: "/opt/homebrew/bin/claude",
            knownCandidates: ["/usr/local/bin/claude"],
            isExecutableFile: { _ in false }
        )
        #expect(result == .failure(.cliNotFound(searchedPaths: [
            "/custom/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"
        ])))
    }

    @Test("run(_:) throws cliNotFound (via the pure resolver) when nothing resolves")
    func runThrowsCliNotFoundWhenUnresolvable() async throws {
        let runner = ClaudeCLIProcessRunner(
            claudePathOverride: nil,
            isExecutableFile: { _ in false },
            whichResolver: { nil }
        )
        let expectedCandidates = [
            "/opt/homebrew/bin/claude",
            ("~/.local/bin/claude" as NSString).expandingTildeInPath,
            "/usr/local/bin/claude"
        ]
        await #expect(throws: LLMClientError.cliNotFound(searchedPaths: expectedCandidates)) {
            _ = try await runner.run(arguments: [], stdin: "", timeout: .seconds(5))
        }
    }

    // MARK: - run(_:) end-to-end against harmless system binaries

    @Test("run(_:) captures stdout from a real subprocess")
    func runCapturesStdoutFromRealProcess() async throws {
        let runner = ClaudeCLIProcessRunner(
            claudePathOverride: "/bin/echo",
            isExecutableFile: { _ in true },
            whichResolver: { nil }
        )
        let stdout = try await runner.run(arguments: ["hello world"], stdin: "", timeout: .seconds(5))
        #expect(stdout == "hello world\n")
    }

    @Test("run(_:) drains stdout well past the pipe buffer without deadlocking")
    func runDrainsLargeStdoutWithoutDeadlock() async throws {
        // No blocking `wait`-then-read sequence could survive this: `readabilityHandler` must drain
        // stdout concurrently with awaiting termination (section 6.1). `yes` denies needing any
        // stdin; `head -c` caps its otherwise-infinite output at ~200KB, several times past the
        // ~64KB pipe buffer that triggers the classic deadlock.
        let runner = ClaudeCLIProcessRunner(
            claudePathOverride: "/bin/sh",
            isExecutableFile: { _ in true },
            whichResolver: { nil }
        )
        let stdout = try await runner.run(
            arguments: ["-c", "yes x | head -c 200000"],
            stdin: "",
            timeout: .seconds(10)
        )
        #expect(stdout.utf8.count == 200_000)
    }

    @Test("run(_:) throws processFailed with the exit code and captured stderr on nonzero exit")
    func runThrowsProcessFailedOnNonzeroExit() async throws {
        let runner = ClaudeCLIProcessRunner(
            claudePathOverride: "/bin/sh",
            isExecutableFile: { _ in true },
            whichResolver: { nil }
        )
        await #expect(throws: LLMClientError.processFailed(exitCode: 3, stderr: "boom\n")) {
            _ = try await runner.run(arguments: ["-c", "echo boom 1>&2; exit 3"], stdin: "", timeout: .seconds(5))
        }
    }

    @Test("run(_:) times out, kills the child, and returns promptly rather than hanging")
    func runTimesOutAndKillsChild() async throws {
        let runner = ClaudeCLIProcessRunner(
            claudePathOverride: "/bin/sleep",
            isExecutableFile: { _ in true },
            whichResolver: { nil }
        )
        let start = ContinuousClock.now
        await #expect(throws: LLMClientError.timedOut(.milliseconds(200))) {
            _ = try await runner.run(arguments: ["30"], stdin: "", timeout: .milliseconds(200))
        }
        let elapsed = ContinuousClock.now - start
        // Must return once the SIGTERM/grace-period/SIGKILL escalation completes and the child is
        // reaped -- nowhere near its full 30s sleep. Proves the child was actually killed, not
        // merely abandoned (which would leak a zombie/orphan process).
        #expect(elapsed < .seconds(5))
    }
}
