import Darwin
import Foundation
import OSLog

// MARK: - LLMProcessRunner

/// Abstracts the `claude` CLI subprocess invocation so `LLMClient` can be unit-tested without
/// spawning a real process (`docs/design/12-llm-client.md` section 7, layer 1). Implementations own
/// argument execution end-to-end, including timeout enforcement (section 6.1: "タイムアウトの所有は
/// runner が正") -- `LLMClient` never races a second timeout on top of this.
///
/// - Throws: Implementations are expected to throw `LLMClientError.timedOut`/`.processFailed` for
///   the documented subprocess failure modes; a test `FakeProcessRunner` just throws these directly.
protocol LLMProcessRunner: Sendable {
    /// - Returns: The child process's captured stdout.
    func run(arguments: [String], stdin: String, timeout: Duration) async throws -> String
}

// MARK: - ClaudeCLIProcessRunner

/// Production `LLMProcessRunner`: launches `claude` as a subprocess and awaits it without blocking
/// the Swift concurrency thread pool (`docs/design/12-llm-client.md` section 6/6.1).
///
/// An `actor` so `resolveClaudePath()`'s cached result is race-free across concurrent `run()` calls.
/// This does **not** by itself serialize `run()` calls to a single CLI process -- concurrent callers
/// each spawn their own subprocess (section 4's "並行度" note is about `LLMClient`, not this runner).
actor ClaudeCLIProcessRunner: LLMProcessRunner {
    private let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "ClaudeCLIProcessRunner")

    /// Explicit override (section 3.1 step 1), wired from `AppConfig.shared.data.llm.claude.cliPath`
    /// by `LLMClient.makeBackend(from:)` (`docs/design/14-llm-provider.md` section 3). This runner
    /// deliberately does not read `AppConfig` itself, keeping this module config-agnostic per the
    /// design doc's stated interface boundary.
    private let claudePathOverride: String?

    /// Injectable so path-resolution tests are fully deterministic (section 7: "候補順・不在時
    /// `cliNotFound` を pure に検証") without touching the real filesystem. Defaults to a real
    /// executable-bit check.
    private let isExecutableFile: @Sendable (String) -> Bool

    /// Injectable so path-resolution tests never actually spawn a login shell (which would be
    /// non-deterministic -- it would find whatever `claude` install happens to exist on the machine
    /// running the tests). Defaults to `Self.resolveViaLoginShellWhich`.
    private let whichResolver: @Sendable () async -> String?

    /// Known-good install locations to probe as a last resort (section 3.1 step 3). Order matters:
    /// Homebrew's Apple Silicon prefix first, then user-local installs, then Homebrew's Intel prefix.
    private static let knownCandidatePaths = [
        "/opt/homebrew/bin/claude",
        ("~/.local/bin/claude" as NSString).expandingTildeInPath,
        "/usr/local/bin/claude"
    ]

    /// Grace period between SIGTERM and SIGKILL when a call times out (section 6.1).
    private static let terminationGracePeriod: Duration = .seconds(2)

    /// Timeout for the `which claude` login-shell probe itself (section 3.1 step 2). Short: this is
    /// a local shell startup, not a network call.
    private static let whichResolutionTimeout: Duration = .seconds(5)

    /// Logger for the `static` subprocess primitive below, which has no instance to reach `logger` on.
    private static let processLogger = Logger(subsystem: "io.github.uphy.Kikimi", category: "ClaudeCLIProcessRunner")

    /// Disposes of `SIGPIPE` process-wide, exactly once, before the first subprocess launch
    /// (`docs/design/38-session-chat.md` §8.1(a)). Writing to a pipe whose read end is gone -- which
    /// is the *normal* outcome whenever a child exits or is killed before consuming all of stdin --
    /// raises `SIGPIPE`, and its default disposition terminates the whole process. Ignoring it turns
    /// the same condition into `EPIPE`, which `FileHandle.write(contentsOf:)` reports as a thrown
    /// Swift error the stdin-writer task below can simply swallow.
    ///
    /// Set here rather than in `KikimiApp`'s launch (as the design doc first sketched) so the unit
    /// test target -- where the "child never reads a >64KB stdin, then gets SIGKILLed" regression
    /// test lives -- is covered by the same guarantee as the app.
    private static let sigpipeIgnored: Void = {
        signal(SIGPIPE, SIG_IGN)
    }()

    private var cachedResolvedPath: String?

    init(
        claudePathOverride: String? = nil,
        isExecutableFile: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        whichResolver: @escaping @Sendable () async -> String? = { await ClaudeCLIProcessRunner.resolveViaLoginShellWhich() }
    ) {
        self.claudePathOverride = claudePathOverride
        self.isExecutableFile = isExecutableFile
        self.whichResolver = whichResolver
    }

    // MARK: - LLMProcessRunner

    func run(arguments: [String], stdin: String, timeout: Duration) async throws -> String {
        let executablePath = try await resolveClaudePath()
        let result = try await Self.runProcess(
            executableURL: URL(fileURLWithPath: executablePath),
            arguments: arguments,
            stdin: stdin,
            timeout: timeout
        )
        switch result {
        case .timedOut:
            throw LLMClientError.timedOut(timeout)
        case .completed(let outcome):
            guard outcome.exitCode == 0 else {
                throw LLMClientError.processFailed(exitCode: outcome.exitCode, stderr: outcome.stderr)
            }
            return outcome.stdout
        }
    }

    // MARK: - Path resolution (section 3.1)

    private func resolveClaudePath() async throws -> String {
        if let cachedResolvedPath {
            return cachedResolvedPath
        }

        // Short-circuits before ever calling `whichResolver()` (which spawns a login shell) when the
        // explicit override already resolves -- the common case once `AppConfig.llm.claude_path` is
        // configured.
        if let claudePathOverride, isExecutableFile(claudePathOverride) {
            cachedResolvedPath = claudePathOverride
            return claudePathOverride
        }

        let whichResult = await whichResolver()
        switch Self.resolveExecutablePath(override: claudePathOverride, whichResult: whichResult, isExecutableFile: isExecutableFile) {
        case .success(let path):
            cachedResolvedPath = path
            return path
        case .failure(let error):
            logger.warning("claude CLI not found: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    /// Pure decision function backing `resolveClaudePath()` (section 3.1): given the already-fetched
    /// `whichResult`, walks override → which-result → known candidates in priority order, testing
    /// each with `isExecutableFile`. `internal` (not `private`) and side-effect-free so
    /// path-resolution tests can exercise the exact ordering and `cliNotFound` behavior
    /// deterministically without spawning any process or touching the real filesystem (section 7:
    /// "候補順・不在時 `cliNotFound` を pure に検証").
    static func resolveExecutablePath(
        override: String?,
        whichResult: String?,
        knownCandidates: [String] = knownCandidatePaths,
        isExecutableFile: (String) -> Bool
    ) -> Result<String, LLMClientError> {
        var searchedPaths: [String] = []

        if let override {
            searchedPaths.append(override)
            if isExecutableFile(override) {
                return .success(override)
            }
        }
        if let whichResult {
            searchedPaths.append(whichResult)
            if isExecutableFile(whichResult) {
                return .success(whichResult)
            }
        }
        for candidate in knownCandidates {
            searchedPaths.append(candidate)
            if isExecutableFile(candidate) {
                return .success(candidate)
            }
        }
        return .failure(.cliNotFound(searchedPaths: searchedPaths))
    }

    /// Resolves `claude` via a login shell's `PATH` (section 3.1 step 2): GUI apps launched from
    /// Finder/LSUIElement don't inherit the user's interactive shell `PATH`, so probing this
    /// process's own environment would miss Homebrew/nvm/asdf-managed installs. Goes through
    /// `runProcess` like every other subprocess call in this type, so it never blocks the
    /// concurrency thread pool either (section 6.1's non-blocking contract applies here too, not
    /// just to the main `claude -p` call).
    fileprivate static func resolveViaLoginShellWhich() async -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard let result = try? await runProcess(
            executableURL: URL(fileURLWithPath: shell),
            arguments: ["-l", "-c", "which claude"],
            stdin: "",
            timeout: whichResolutionTimeout
        ), case .completed(let outcome) = result, outcome.exitCode == 0 else {
            return nil
        }
        let trimmed = outcome.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Non-blocking subprocess primitive (section 6.1)

    /// Raw outcome of running an arbitrary subprocess, without interpreting the exit code -- that's
    /// left to the caller (`run(...)` maps non-zero to `.processFailed`; `resolveViaLoginShellWhich`
    /// just checks `exitCode == 0`).
    private struct RawProcessOutcome {
        var exitCode: Int32
        var stdout: String
        var stderr: String
    }

    private enum RawProcessResult {
        case completed(RawProcessOutcome)
        case timedOut
    }

    /// The shared non-blocking subprocess primitive used both by `run(...)` (the `claude -p` call)
    /// and `resolveViaLoginShellWhich()` (the `PATH` probe). Launches `executableURL`, feeds `stdin`,
    /// drains stdout/stderr *concurrently* with awaiting termination (section 6.1's pipe-deadlock
    /// avoidance: a 64KB+ stdout write would otherwise deadlock a
    /// wait-then-read-to-end-of-file sequence), and enforces `timeout` by escalating
    /// SIGTERM → grace period → SIGKILL, reaping the child and closing both `Pipe`s' FDs before
    /// returning either way (section 6.1: "必ず子プロセスを reap し、両 `Pipe` の FD を close して
    /// から").
    ///
    /// `stdin` is written from a detached task rather than inline, so a prompt larger than the
    /// 64KB pipe buffer cannot block this function before the timeout is armed
    /// (`docs/design/38-session-chat.md` §8.1(a)); see the write site below.
    ///
    /// Never calls `Process.waitUntilExit()`/`FileHandle.readDataToEndOfFile()` -- see the type doc.
    private static func runProcess(
        executableURL: URL,
        arguments: [String],
        stdin: String,
        timeout: Duration
    ) async throws -> RawProcessResult {
        _ = sigpipeIgnored

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutBuffer = ProcessOutputBuffer()
        let stderrBuffer = ProcessOutputBuffer()
        // Registered before `run()` so no early output is missed; read concurrently with awaiting
        // termination below (section 6.1).
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty {
                stdoutBuffer.append(chunk)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty {
                stderrBuffer.append(chunk)
            }
        }

        let termination = ProcessTermination()
        process.terminationHandler = { finishedProcess in
            Task { await termination.signal(exitCode: finishedProcess.terminationStatus) }
        }

        func closeReadPipes() {
            // Unregistering before `close()` avoids a stray callback firing on an already-closed FD
            // (section 6.1: "正常終了経路でも `readabilityHandler` を外して FD を確実に閉じる").
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
        }

        do {
            try process.run()
        } catch {
            closeReadPipes()
            throw LLMClientError.processFailed(
                exitCode: -1,
                stderr: "failed to launch \(executableURL.path): \(error.localizedDescription)"
            )
        }

        // Fed from a detached task so the timeout race below starts *now*, not after the write
        // finishes (`docs/design/38-session-chat.md` §8.1(a)/CH20). A macOS pipe buffers at most
        // 64KB, so any prompt past that -- which the chat feature's `max_context_chars: 120000`
        // (~360KB in Japanese UTF-8) always is -- blocks until the child drains it. Writing
        // synchronously here would (a) make a child that never reads stdin hang this call forever,
        // with the timeout not yet even armed, and (b) block a cooperative-thread-pool thread for
        // hundreds of milliseconds in the normal case, alongside live STT and refinement.
        let stdinHandle = stdinPipe.fileHandleForWriting
        let stdinData = stdin.data(using: .utf8) ?? Data()
        Task.detached(priority: .utility) {
            // Closing the write end is what makes the child see EOF instead of blocking on a read,
            // so it has to happen on every exit path -- including a failed write.
            defer { try? stdinHandle.close() }
            guard !stdinData.isEmpty else { return }
            do {
                // `write(contentsOf:)`, not `write(_:)`: the latter raises an ObjC exception on
                // EPIPE, which is not catchable in Swift and would take the app down. A child that
                // exits early is an ordinary outcome here, not a crash.
                try stdinHandle.write(contentsOf: stdinData)
            } catch {
                // Expected whenever the child exits (or is SIGKILLed after a timeout) before
                // reading all of stdin. The real outcome is reported by the race below.
                processLogger.debug("stdin write ended early: \(error.localizedDescription, privacy: .public)")
            }
        }

        let outcome = await race(termination: termination, timeout: timeout)
        switch outcome {
        case .exited(let exitCode):
            let stdoutString = String(data: stdoutBuffer.accumulated, encoding: .utf8) ?? ""
            let stderrString = String(data: stderrBuffer.accumulated, encoding: .utf8) ?? ""
            closeReadPipes()
            return .completed(RawProcessOutcome(exitCode: exitCode, stdout: stdoutString, stderr: stderrString))
        case .timedOut:
            process.terminate() // SIGTERM
            let graceOutcome = await race(termination: termination, timeout: terminationGracePeriod)
            if case .timedOut = graceOutcome, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            // Guaranteed to resolve: SIGTERM (if it already worked) or SIGKILL (uncatchable/
            // unignorable) both lead to `terminationHandler` eventually firing, so this never hangs.
            _ = await termination.wait()
            closeReadPipes()
            return .timedOut
        }
    }

    // MARK: - Termination tracking + timeout race

    /// Tracks a `Process`'s exit via `terminationHandler`, decoupled from any particular timeout race
    /// so a caller can keep awaiting it after abandoning a race (needed to actually reap the child
    /// once killed following a timeout; see `runProcess`'s `.timedOut` branch).
    private actor ProcessTermination {
        private var exitCode: Int32?
        private var waiters: [CheckedContinuation<Int32, Never>] = []

        func signal(exitCode: Int32) {
            guard self.exitCode == nil else { return }
            self.exitCode = exitCode
            let pending = waiters
            waiters.removeAll()
            for waiter in pending {
                waiter.resume(returning: exitCode)
            }
        }

        func wait() async -> Int32 {
            if let exitCode {
                return exitCode
            }
            return await withCheckedContinuation { waiters.append($0) }
        }
    }

    private enum ProcessRaceOutcome {
        case exited(Int32)
        case timedOut
    }

    /// Ensures a race's continuation is resumed exactly once, even though both racing branches below
    /// call `claim()` independently.
    private actor ResumeOnce {
        private var claimed = false
        func claim() -> Bool {
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }

    /// Races `termination` against a `timeout` sleep.
    ///
    /// Deliberately built from two unstructured `Task`s reporting into one continuation rather than
    /// `withTaskGroup`: `termination.wait()` cannot be cancelled (there is no way to interrupt a real
    /// OS process exit by cancelling a Swift `Task`), and a task group's scope always awaits *every*
    /// child before returning -- using one here would make this function block until the race's
    /// *loser* also finishes, defeating the entire point of a timeout (section 6.1).
    private static func race(termination: ProcessTermination, timeout: Duration) async -> ProcessRaceOutcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<ProcessRaceOutcome, Never>) in
            let gate = ResumeOnce()
            Task {
                let exitCode = await termination.wait()
                if await gate.claim() {
                    continuation.resume(returning: .exited(exitCode))
                }
            }
            Task {
                try? await Task.sleep(for: timeout)
                if await gate.claim() {
                    continuation.resume(returning: .timedOut)
                }
            }
        }
    }
}

// MARK: - ProcessOutputBuffer

/// Thread-safe accumulator for output read on `Pipe.fileHandleForReading.readabilityHandler`'s
/// delivery queue, concurrently with the actor awaiting process termination (section 6.1: "stdout は
/// wait と並行に吸い出す"). A lock-protected class (rather than an actor) because
/// `readabilityHandler`'s closure is synchronous and must not itself suspend.
private final class ProcessOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var accumulated: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}
