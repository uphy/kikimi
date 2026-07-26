import Foundation
import Testing

@testable import Kikimi

/// `LLMClient`'s own responsibilities (`docs/design/14-llm-provider.md` section 2): the stub-mode
/// branch (section 5), the shared `structuredJSON` → `T` `.convertFromSnakeCase` decode every backend
/// goes through, and `healthCheck`. Full-pipeline tests here wire a real `ClaudeCLIBackend` to a
/// `FakeProcessRunner` (`ClaudeCLIBackendTests.swift`) so `LLMClient`'s decode step is exercised
/// end-to-end the same way the pre-split `LLMClientTests` did; `ClaudeCLIBackend`'s own
/// argument-building/envelope-parsing behavior is covered in `ClaudeCLIBackendTests.swift` instead.
@Suite("LLMClient")
struct LLMClientTests {
    private func makeClient(runner: FakeProcessRunner, environment: [String: String] = [:]) -> LLMClient {
        LLMClient(backend: ClaudeCLIBackend(runner: runner), environment: environment)
    }

    // MARK: - Full pipeline: backend -> shared T decode

    @Test("decodes structured_output and usage from a well-formed CLI response, end to end")
    func decodesWellFormedResponse() async throws {
        let runner = FakeProcessRunner(stdoutToReturn: makeCLIResponseLine())
        let client = makeClient(runner: runner)

        let result: LLMResult<SamplePayload> = try await client.complete(makeRequest())

        #expect(result.value == SamplePayload(title: "hello", count: 3))
        #expect(result.usage == LLMUsage(inputTokens: 10, outputTokens: 5, cacheReadInputTokens: 2, cacheCreationInputTokens: 1, totalCostUSD: 0.0031))
        #expect(await runner.callCount == 1)
    }

    @Test("structured_output that doesn't match T throws decodeFailed")
    func mismatchedStructuredOutputThrowsDecodeFailed() async throws {
        let runner = FakeProcessRunner(stdoutToReturn: makeCLIResponseLine(structuredOutput: "{\"unexpected\":true}"))
        let client = makeClient(runner: runner)

        do {
            let _: LLMResult<SamplePayload> = try await client.complete(makeRequest())
            Issue.record("expected decodeFailed to be thrown")
        } catch let error as LLMClientError {
            guard case .decodeFailed = error else {
                Issue.record("expected decodeFailed, got \(error)")
                return
            }
        }
    }

    @Test("a backend-thrown timedOut propagates unchanged")
    func backendTimeoutPropagates() async throws {
        let runner = FakeProcessRunner(errorToThrow: LLMClientError.timedOut(.seconds(60)))
        let client = makeClient(runner: runner)

        await #expect(throws: LLMClientError.timedOut(.seconds(60))) {
            let _: LLMResult<SamplePayload> = try await client.complete(makeRequest())
        }
    }

    @Test("a backend-thrown processFailed propagates unchanged")
    func backendProcessFailurePropagates() async throws {
        let runner = FakeProcessRunner(errorToThrow: LLMClientError.processFailed(exitCode: 2, stderr: "boom"))
        let client = makeClient(runner: runner)

        await #expect(throws: LLMClientError.processFailed(exitCode: 2, stderr: "boom")) {
            let _: LLMResult<SamplePayload> = try await client.complete(makeRequest())
        }
    }

    // MARK: - Stub mode (section 5)

    @Test("KIKIMI_STUB_LLM=1 returns the stub response and never calls the backend")
    func stubModeBypassesBackend() async throws {
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("LLMClientTests-stub-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempFile) }
        let stubMap = ["summary_patch": "{\"title\":\"stubbed\",\"count\":42}"]
        try JSONEncoder().encode(stubMap).write(to: tempFile)

        let runner = FakeProcessRunner(stdoutToReturn: "should never be read")
        let client = makeClient(runner: runner, environment: ["KIKIMI_STUB_LLM": "1", "KIKIMI_STUB_LLM_FILE": tempFile.path])

        let result: LLMResult<SamplePayload> = try await client.complete(makeRequest(stubKey: "summary_patch"))

        #expect(result.value == SamplePayload(title: "stubbed", count: 42))
        #expect(result.usage == .zero)
        #expect(await runner.callCount == 0)
    }

    @Test("stub mode with an unregistered stubKey throws missingStructuredOutput without calling the backend")
    func stubModeUnknownKeyThrowsMissingStructuredOutput() async throws {
        let runner = FakeProcessRunner(stdoutToReturn: "should never be read")
        let client = makeClient(runner: runner, environment: ["KIKIMI_STUB_LLM": "1"])

        do {
            let _: LLMResult<SamplePayload> = try await client.complete(makeRequest(stubKey: "unregistered"))
            Issue.record("expected missingStructuredOutput to be thrown")
        } catch LLMClientError.missingStructuredOutput {
            // expected
        }
        #expect(await runner.callCount == 0)
    }

    // MARK: - completeRaw (`docs/design/05-watcher-runner.md` §5.1)

    @Test("completeRaw in stub mode returns the stub response undecoded and never calls the backend")
    func completeRawStubModeBypassesBackend() async throws {
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("LLMClientTests-stub-raw-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempFile) }
        let stubMap = ["watcher_pre-check": "{\"source_seg_id\":\"seg_00001\"}"]
        try JSONEncoder().encode(stubMap).write(to: tempFile)

        let runner = FakeProcessRunner(stdoutToReturn: "should never be read")
        let client = makeClient(runner: runner, environment: ["KIKIMI_STUB_LLM": "1", "KIKIMI_STUB_LLM_FILE": tempFile.path])

        let result = try await client.completeRaw(makeRequest(stubKey: "watcher_pre-check"))

        // Raw bytes are returned undecoded -- in particular, `source_seg_id` is NOT transformed into
        // a `sourceSegId` camelCase key the way `complete<T>`'s `.convertFromSnakeCase` decode would.
        let text = String(data: result.value, encoding: .utf8)
        #expect(text == "{\"source_seg_id\":\"seg_00001\"}")
        #expect(result.usage == .zero)
        #expect(await runner.callCount == 0)
    }

    @Test("completeRaw in production mode returns the backend's structuredJSON undecoded")
    func completeRawProductionModeReturnsBackendBytesUndecoded() async throws {
        let runner = FakeProcessRunner(stdoutToReturn: makeCLIResponseLine(structuredOutput: "{\"source_seg_id\":\"seg_00002\"}"))
        let client = makeClient(runner: runner)

        let result = try await client.completeRaw(makeRequest())

        let text = String(data: result.value, encoding: .utf8)
        #expect(text == "{\"source_seg_id\":\"seg_00002\"}")
        #expect(result.usage == LLMUsage(inputTokens: 10, outputTokens: 5, cacheReadInputTokens: 2, cacheCreationInputTokens: 1, totalCostUSD: 0.0031))
        #expect(await runner.callCount == 1)
    }

    @Test("completeRaw in stub mode with an unregistered stubKey throws missingStructuredOutput without calling the backend")
    func completeRawStubModeUnknownKeyThrows() async throws {
        let runner = FakeProcessRunner(stdoutToReturn: "should never be read")
        let client = makeClient(runner: runner, environment: ["KIKIMI_STUB_LLM": "1"])

        await #expect(throws: LLMClientError.self) {
            _ = try await client.completeRaw(makeRequest(stubKey: "unregistered"))
        }
        #expect(await runner.callCount == 0)
    }

    // MARK: - Health check

    @Test("healthCheck reports available in stub mode without calling the backend")
    func healthCheckStubModeIsAlwaysAvailable() async throws {
        let runner = FakeProcessRunner(errorToThrow: LLMClientError.cliNotFound(searchedPaths: []))
        let client = makeClient(runner: runner, environment: ["KIKIMI_STUB_LLM": "1"])

        let result = await client.healthCheck()
        #expect(result == .available)
        #expect(await runner.callCount == 0)
    }

    @Test("healthCheck reports unavailable when the backend cannot find the CLI")
    func healthCheckReportsCLINotFound() async throws {
        let runner = FakeProcessRunner(errorToThrow: LLMClientError.cliNotFound(searchedPaths: ["/opt/homebrew/bin/claude"]))
        let client = makeClient(runner: runner)

        let result = await client.healthCheck()
        #expect(result == .unavailable(.cliNotFound(searchedPaths: ["/opt/homebrew/bin/claude"])))
    }

    @Test("healthCheck reports available when the probe call succeeds")
    func healthCheckReportsAvailable() async throws {
        let runner = FakeProcessRunner(stdoutToReturn: "{\"is_error\":false,\"structured_output\":{\"ok\":true}}")
        let client = makeClient(runner: runner)

        let result = await client.healthCheck()
        #expect(result == .available)
    }

    // MARK: - Backend factory (`docs/design/14-llm-provider.md` section 2/3)

    @Test("makeBackend(from:) builds a ClaudeCLIBackend for the claude-cli provider")
    func makeBackendBuildsClaudeCLIBackend() {
        let backend = LLMClient.makeBackend(
            from: LLMConfig(provider: .claudeCLI, claude: .default, openai: .default),
            credentialStore: InMemoryCredentialStore()
        )
        #expect(backend is ClaudeCLIBackend)
    }

    /// `credentialStore` must be injected: `OpenAIChatBackend.init` resolves the API key eagerly, so
    /// the production default would read the user's real credential store from a unit test
    /// (`docs/design/35-secure-enclave-credentials.md` §4).
    @Test("makeBackend(from:) builds an OpenAIChatBackend for the openai provider")
    func makeBackendBuildsOpenAIChatBackend() {
        let backend = LLMClient.makeBackend(
            from: LLMConfig(provider: .openai, claude: .default, openai: .default),
            credentialStore: InMemoryCredentialStore()
        )
        #expect(backend is OpenAIChatBackend)
    }
}
