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

    // MARK: - Backend factory (`docs/design/44-llm-model-config.md` §5.2/§5.3)

    @Test("makeBackend(name:config:) builds a ClaudeCLIBackend for a claude-cli provider entry")
    func makeBackendBuildsClaudeCLIBackend() {
        let backend = LLMClient.makeBackend(
            name: "claude",
            config: .claudeCLI(.default),
            credentialStore: InMemoryCredentialStore()
        )
        #expect(backend is ClaudeCLIBackend)
    }

    /// `credentialStore` must be injected: `OpenAIChatBackend.init` resolves the API key eagerly, so
    /// the production default would read the user's real credential store from a unit test
    /// (`docs/design/35-secure-enclave-credentials.md` §4).
    @Test("makeBackend(name:config:) builds an OpenAIChatBackend for an openai provider entry")
    func makeBackendBuildsOpenAIChatBackend() {
        let backend = LLMClient.makeBackend(
            name: "azure",
            config: .openai(.default),
            credentialStore: InMemoryCredentialStore()
        )
        #expect(backend is OpenAIChatBackend)
    }

    // MARK: - Registry dispatch (§5.2/§11: "レジストリ dispatch")

    @Test("init(backends:) dispatches a request to the backend registered under request.provider")
    func registryDispatchesToNamedProvider() async throws {
        let claudeRunner = FakeProcessRunner(stdoutToReturn: makeCLIResponseLine(structuredOutput: "{\"title\":\"from-claude\",\"count\":1}"))
        let azureRunner = FakeProcessRunner(stdoutToReturn: makeCLIResponseLine(structuredOutput: "{\"title\":\"from-azure\",\"count\":2}"))
        let client = LLMClient(backends: [
            "claude": ClaudeCLIBackend(runner: claudeRunner),
            "azure": ClaudeCLIBackend(runner: azureRunner)
        ])

        var azureRequest = makeRequest()
        azureRequest.provider = "azure"
        let result: LLMResult<SamplePayload> = try await client.complete(azureRequest)

        #expect(result.value == SamplePayload(title: "from-azure", count: 2))
        #expect(await claudeRunner.callCount == 0)
        #expect(await azureRunner.callCount == 1)
    }

    @Test("init(backends:) dispatches a request with provider == nil to defaultProviderName")
    func registryDispatchesNilProviderToDefault() async throws {
        let defaultRunner = FakeProcessRunner(stdoutToReturn: makeCLIResponseLine())
        let otherRunner = FakeProcessRunner(stdoutToReturn: makeCLIResponseLine())
        let client = LLMClient(backends: [
            "claude": ClaudeCLIBackend(runner: defaultRunner),
            "azure": ClaudeCLIBackend(runner: otherRunner)
        ], defaultProviderName: "claude")

        let _: LLMResult<SamplePayload> = try await client.complete(makeRequest())

        #expect(await defaultRunner.callCount == 1)
        #expect(await otherRunner.callCount == 0)
    }

    @Test("a request naming a provider absent from the registry throws unknownProvider")
    func unregisteredProviderThrowsUnknownProvider() async throws {
        let client = LLMClient(backends: ["claude": ClaudeCLIBackend(runner: FakeProcessRunner())])

        var request = makeRequest()
        request.provider = "azure"

        await #expect(throws: LLMClientError.unknownProvider(name: "azure")) {
            let _: LLMResult<SamplePayload> = try await client.complete(request)
        }
    }

    @Test("init(backend:) back-compat: a request with provider == nil reaches the single registered backend")
    func initBackendBackCompatDispatchesNilProviderRequests() async throws {
        let runner = FakeProcessRunner(stdoutToReturn: makeCLIResponseLine())
        let client = LLMClient(backend: ClaudeCLIBackend(runner: runner))

        let result: LLMResult<SamplePayload> = try await client.complete(makeRequest())

        #expect(result.value == SamplePayload(title: "hello", count: 3))
        #expect(await runner.callCount == 1)
    }

    @Test("stub mode dispatches before the registry: an unknown provider request never reaches backend(for:)")
    func stubModeBypassesRegistryEvenForAnUnknownProvider() async throws {
        // §5.2's invariant: "スタブ分岐はレジストリ参照より前段" -- a request naming a provider that
        // isn't in the registry at all must still resolve from the stub map in stub mode, never
        // throwing `.unknownProvider`.
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("LLMClientTests-stub-registry-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempFile) }
        let stubMap = ["summary_patch": "{\"title\":\"stubbed\",\"count\":42}"]
        try JSONEncoder().encode(stubMap).write(to: tempFile)

        let client = LLMClient(backends: [:], environment: ["KIKIMI_STUB_LLM": "1", "KIKIMI_STUB_LLM_FILE": tempFile.path])

        var request = makeRequest(stubKey: "summary_patch")
        request.provider = "totally-unregistered"
        let result: LLMResult<SamplePayload> = try await client.complete(request)

        #expect(result.value == SamplePayload(title: "stubbed", count: 42))
    }

    // MARK: - Lazy construction (§5.2/§11: "遅延構築")

    /// Records every `read(account:)` call so a test can assert an unused provider's credential is
    /// never touched.
    private final class RecordingCredentialStore: CredentialStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var backing: [String: String] = [:]
        private(set) var readAccounts: [String] = []

        func read(account: String) -> String? {
            lock.lock()
            defer { lock.unlock() }
            readAccounts.append(account)
            return backing[account]
        }

        func write(_ value: String, account: String) throws {
            lock.lock()
            defer { lock.unlock() }
            backing[account] = value
        }

        func delete(account: String) throws {
            lock.lock()
            defer { lock.unlock() }
            backing.removeValue(forKey: account)
        }
    }

    @Test("a provider's backend is never constructed -- and its credential never read -- until a request names it")
    func lazyConstructionSkipsCredentialReadForUnusedProviders() async throws {
        let credentialStore = RecordingCredentialStore()
        let config = LLMConfig(
            provider: .claudeCLI, claude: .default, openai: .default, pricing: [:],
            providers: [
                // `/bin/echo` stands in for the CLI executable: it exists and is executable (so path
                // resolution never spawns a real `which claude` login shell -- deterministic, and
                // no risk of finding/invoking a real `claude` install), and its stdout ("-p ... " etc.
                // echoed back verbatim) is never valid JSON, so `complete(_:)` fails fast with
                // `invalidJSON` -- irrelevant to what this test checks.
                "claude": .claudeCLI(ClaudeBackendConfig(cliPath: "/bin/echo")),
                "azure": .openai(OpenAIBackendConfig(baseURL: "https://example.invalid", apiKey: "", apiKeyEnv: "", apiVersion: "", model: "", authHeader: "", reasoningEffort: ""))
            ],
            models: [:], defaultAlias: "", defaultProviderName: "claude"
        )
        let client = LLMClient(config: config, credentialStore: credentialStore)
        let request = LLMRequest(
            system: "system prompt", user: "user prompt", schema: "{\"type\":\"object\"}",
            model: "claude-haiku-4-5-20251001", timeout: .seconds(5)
        )
        // `claude`'s backend build path never touches the credential store at all (no API key
        // involved), so exercising it alone is enough to prove `azure`'s account was never read.
        _ = try? await client.complete(request) as LLMResult<SamplePayload>

        #expect(credentialStore.readAccounts.isEmpty, "azure's backend must not be constructed -- and its credential must not be read -- when only claude is ever dispatched to")
    }

    // MARK: - availableProviders (§5.2/§11)

    @Test("availableProviders is providerConfigs' keys plus the builtin claude, excluding decode-dropped entries")
    func availableProvidersReflectsProviderConfigsPlusBuiltin() {
        let config = LLMConfig(
            provider: .claudeCLI, claude: .default, openai: .default, pricing: [:],
            providers: ["azure": .openai(.default), "on-prem": .claudeCLI(.default)],
            models: [:], defaultAlias: "auto", defaultProviderName: nil
        )
        let client = LLMClient(config: config, credentialStore: InMemoryCredentialStore())

        #expect(client.availableProviders == ["azure", "on-prem", ModelResolver.builtinProviderName])
    }

    @Test("availableProviders always includes the builtin claude provider even when llm.providers is empty")
    func availableProvidersAlwaysIncludesBuiltin() {
        let config = LLMConfig(
            provider: .claudeCLI, claude: .default, openai: .default, pricing: [:],
            providers: [:], models: [:], defaultAlias: "auto", defaultProviderName: nil
        )
        let client = LLMClient(config: config, credentialStore: InMemoryCredentialStore())

        #expect(client.availableProviders == [ModelResolver.builtinProviderName])
    }
}
