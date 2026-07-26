import Foundation
import Testing

@testable import Kikimi

// MARK: - FakeProcessRunner

/// Deterministic, network-free stand-in for `ClaudeCLIProcessRunner`
/// (`docs/design/12-llm-client.md` section 7, layer 1: "CLI 起動部分をプロトコルで抽象化").
/// An `actor` (like `ClaudeCLIProcessRunner` itself) so call-count/received-argument assertions are
/// race-free. Not `private` -- shared with `LLMClientTests.swift`, which wires it through
/// `ClaudeCLIBackend` for its own full-pipeline coverage.
actor FakeProcessRunner: LLMProcessRunner {
    private(set) var callCount = 0
    private(set) var lastArguments: [String]?
    private(set) var lastStdin: String?
    private(set) var lastTimeout: Duration?

    var stdoutToReturn = ""
    var errorToThrow: Error?

    init(stdoutToReturn: String = "", errorToThrow: Error? = nil) {
        self.stdoutToReturn = stdoutToReturn
        self.errorToThrow = errorToThrow
    }

    func run(arguments: [String], stdin: String, timeout: Duration) async throws -> String {
        callCount += 1
        lastArguments = arguments
        lastStdin = stdin
        lastTimeout = timeout
        if let errorToThrow {
            throw errorToThrow
        }
        return stdoutToReturn
    }
}

// MARK: - Fixtures

/// The structured-output type most tests decode `structured_output` into. Not `private` -- shared
/// with `LLMClientTests.swift`.
struct SamplePayload: Decodable, Sendable, Equatable {
    var title: String
    var count: Int
}

/// Not `private` -- shared with `LLMClientTests.swift`.
func makeRequest(stubKey: String? = nil, timeout: Duration = .seconds(30)) -> LLMRequest {
    LLMRequest(
        system: "system prompt",
        user: "user prompt",
        schema: "{\"type\":\"object\"}",
        model: "claude-haiku-4-5-20251001",
        timeout: timeout,
        stubKey: stubKey
    )
}

/// A well-formed CLI response line, matching section 2.1/6.2's documented shape. Not `private` --
/// shared with `LLMClientTests.swift`.
func makeCLIResponseLine(
    isError: Bool = false,
    structuredOutput: String? = "{\"title\":\"hello\",\"count\":3}",
    subtype: String? = nil,
    apiErrorStatus: Int? = nil
) -> String {
    var fields: [String] = ["\"is_error\":\(isError)"]
    if let structuredOutput {
        fields.append("\"structured_output\":\(structuredOutput)")
    }
    if let subtype {
        fields.append("\"subtype\":\"\(subtype)\"")
    }
    if let apiErrorStatus {
        fields.append("\"api_error_status\":\(apiErrorStatus)")
    }
    fields.append("\"usage\":{\"input_tokens\":10,\"output_tokens\":5,\"cache_creation_input_tokens\":1,\"cache_read_input_tokens\":2}")
    fields.append("\"total_cost_usd\":0.0031")
    return "{" + fields.joined(separator: ",") + "}"
}

/// `.convertFromSnakeCase` decode helper mirroring `LLMClient.runAndDecode`'s shared `T` decode
/// (`docs/design/12-llm-client.md` section 6.2), so these backend-level tests can assert against a
/// concrete decoded value the same way the original (pre-split) `LLMClientTests` did.
private func decodeSamplePayload(_ data: Data) throws -> SamplePayload {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(SamplePayload.self, from: data)
}

/// Layer 1 coverage for `ClaudeCLIBackend` (`docs/design/14-llm-provider.md` section 2: "既存実装の
/// 移設"). These tests were moved unchanged in assertion content from the pre-split `LLMClientTests`
/// (`docs/design/14-llm-provider.md` section 6), covering `ClaudeCLIBackend.buildArguments` and
/// `.decodeEnvelope` -- the argument-building and CLI-response-envelope-parsing logic that used to
/// live directly on `LLMClient`.
@Suite("ClaudeCLIBackend")
struct ClaudeCLIBackendTests {
    // MARK: - complete(_:) via FakeProcessRunner

    @Test("decodes structured_output and usage from a well-formed CLI response")
    func decodesWellFormedResponse() async throws {
        let runner = FakeProcessRunner(stdoutToReturn: makeCLIResponseLine())
        let backend = ClaudeCLIBackend(runner: runner)

        let response = try await backend.complete(makeRequest())

        #expect(try decodeSamplePayload(response.structuredJSON) == SamplePayload(title: "hello", count: 3))
        #expect(response.usage == LLMUsage(inputTokens: 10, outputTokens: 5, cacheReadInputTokens: 2, cacheCreationInputTokens: 1, totalCostUSD: 0.0031))
        #expect(await runner.callCount == 1)
    }

    @Test("tolerates a leading warning line, using only the last non-empty line")
    func tolerantOfLeadingWarningLines() async throws {
        let stdout = "warning: something noisy\n\n" + makeCLIResponseLine()
        let runner = FakeProcessRunner(stdoutToReturn: stdout)
        let backend = ClaudeCLIBackend(runner: runner)

        let response = try await backend.complete(makeRequest())
        #expect(try decodeSamplePayload(response.structuredJSON) == SamplePayload(title: "hello", count: 3))
    }

    @Test("is_error true without an auth signal throws missingStructuredOutput")
    func isErrorWithoutStructuredOutputThrowsMissingStructuredOutput() async throws {
        let raw = makeCLIResponseLine(isError: true, structuredOutput: nil)
        let runner = FakeProcessRunner(stdoutToReturn: raw)
        let backend = ClaudeCLIBackend(runner: runner)

        await #expect(throws: LLMClientError.missingStructuredOutput(raw: raw)) {
            _ = try await backend.complete(makeRequest())
        }
    }

    @Test("is_error true with api_error_status 401 throws notAuthenticated")
    func isErrorWithAuthStatusThrowsNotAuthenticated() async throws {
        let runner = FakeProcessRunner(stdoutToReturn: makeCLIResponseLine(isError: true, structuredOutput: nil, apiErrorStatus: 401))
        let backend = ClaudeCLIBackend(runner: runner)

        await #expect(throws: LLMClientError.notAuthenticated) {
            _ = try await backend.complete(makeRequest())
        }
    }

    @Test("is_error true with a known auth subtype throws notAuthenticated")
    func isErrorWithAuthSubtypeThrowsNotAuthenticated() async throws {
        let runner = FakeProcessRunner(stdoutToReturn: makeCLIResponseLine(isError: true, structuredOutput: nil, subtype: "error_not_logged_in"))
        let backend = ClaudeCLIBackend(runner: runner)

        await #expect(throws: LLMClientError.notAuthenticated) {
            _ = try await backend.complete(makeRequest())
        }
    }

    @Test("malformed JSON throws invalidJSON")
    func malformedJSONThrowsInvalidJSON() async throws {
        let runner = FakeProcessRunner(stdoutToReturn: "not json at all {{{")
        let backend = ClaudeCLIBackend(runner: runner)

        await #expect(throws: LLMClientError.invalidJSON(raw: "not json at all {{{")) {
            _ = try await backend.complete(makeRequest())
        }
    }

    @Test("empty stdout throws invalidJSON")
    func emptyStdoutThrowsInvalidJSON() async throws {
        let runner = FakeProcessRunner(stdoutToReturn: "   \n\n  ")
        let backend = ClaudeCLIBackend(runner: runner)

        await #expect(throws: LLMClientError.invalidJSON(raw: "   \n\n  ")) {
            _ = try await backend.complete(makeRequest())
        }
    }

    @Test("a runner-thrown timedOut propagates unchanged")
    func runnerTimeoutPropagates() async throws {
        let runner = FakeProcessRunner(errorToThrow: LLMClientError.timedOut(.seconds(60)))
        let backend = ClaudeCLIBackend(runner: runner)

        await #expect(throws: LLMClientError.timedOut(.seconds(60))) {
            _ = try await backend.complete(makeRequest())
        }
    }

    @Test("a runner-thrown processFailed propagates unchanged")
    func runnerProcessFailurePropagates() async throws {
        let runner = FakeProcessRunner(errorToThrow: LLMClientError.processFailed(exitCode: 2, stderr: "boom"))
        let backend = ClaudeCLIBackend(runner: runner)

        await #expect(throws: LLMClientError.processFailed(exitCode: 2, stderr: "boom")) {
            _ = try await backend.complete(makeRequest())
        }
    }

    // MARK: - Argument building (section 2.1 pure verification)

    @Test("buildArguments always includes the fixed flag set and forwards model/schema")
    func buildArgumentsIncludesFixedFlags() {
        let request = LLMRequest(
            system: "sys prompt",
            user: "user prompt",
            schema: "{\"type\":\"object\"}",
            model: "claude-haiku-4-5-20251001"
        )
        let arguments = ClaudeCLIBackend.buildArguments(request: request)

        #expect(arguments == [
            "-p",
            "--system-prompt", "sys prompt",
            "--tools",
            "--exclude-dynamic-system-prompt-sections",
            "--setting-sources", "",
            "--output-format", "json",
            "--json-schema", "{\"type\":\"object\"}",
            "--model", "claude-haiku-4-5-20251001"
        ])
    }

    @Test("complete(_:) forwards the built arguments and user prompt (on stdin) to the runner")
    func completeForwardsArgumentsAndStdinToRunner() async throws {
        let runner = FakeProcessRunner(stdoutToReturn: makeCLIResponseLine())
        let backend = ClaudeCLIBackend(runner: runner)
        let request = makeRequest(timeout: .seconds(42))

        _ = try await backend.complete(request)

        let lastArguments = await runner.lastArguments
        #expect(lastArguments == ClaudeCLIBackend.buildArguments(request: request))
        #expect(await runner.lastStdin == "user prompt")
        #expect(await runner.lastTimeout == .seconds(42))
    }
}
