import Foundation
import Testing

@testable import Kikimi

// MARK: - FakeHTTPTransport

/// Deterministic, network-free stand-in for `URLSessionHTTPTransport`
/// (`docs/design/14-llm-provider.md` section 4.3), mirroring `FakeProcessRunner`'s role for
/// `ClaudeCLIBackend`.
private actor FakeHTTPTransport: HTTPTransporting {
    private(set) var callCount = 0
    private(set) var lastRequest: URLRequest?

    var dataToReturn = Data()
    var statusCodeToReturn = 200
    var errorToThrow: Error?

    init(dataToReturn: Data = Data(), statusCodeToReturn: Int = 200, errorToThrow: Error? = nil) {
        self.dataToReturn = dataToReturn
        self.statusCodeToReturn = statusCodeToReturn
        self.errorToThrow = errorToThrow
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        callCount += 1
        lastRequest = request
        if let errorToThrow {
            throw errorToThrow
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCodeToReturn,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (dataToReturn, response)
    }
}

// MARK: - Fixtures

private func makeConfig(
    baseURL: String = "https://api.openai.com/v1",
    apiKey: String = "sk-test",
    apiKeyEnv: String = "",
    apiVersion: String = "",
    model: String = "",
    authHeader: String = "",
    reasoningEffort: String = ""
) -> OpenAIBackendConfig {
    OpenAIBackendConfig(baseURL: baseURL, apiKey: apiKey, apiKeyEnv: apiKeyEnv, apiVersion: apiVersion, model: model, authHeader: authHeader, reasoningEffort: reasoningEffort)
}

/// Test-only convenience over `OpenAIChatBackend.init`: defaults `credentialStore` to a fresh, empty
/// `InMemoryCredentialStore()` per call so every `complete(_:)` test in this file resolves its API
/// key purely from `config`/`environment`, never the real Keychain (`docs/design/26-settings-ui.md`
/// §6.1).
private func makeBackend(
    config: OpenAIBackendConfig,
    transport: HTTPTransporting,
    environment: [String: String] = [:],
    credentialStore: CredentialStoring = InMemoryCredentialStore()
) -> OpenAIChatBackend {
    OpenAIChatBackend(config: config, transport: transport, environment: environment, credentialStore: credentialStore)
}

private func makeChatRequest(model: String = "gpt-4o-mini", timeout: Duration = .seconds(30)) -> LLMRequest {
    LLMRequest(
        system: "system prompt",
        user: "user prompt",
        schema: "{\"type\":\"object\",\"properties\":{\"title\":{\"type\":\"string\"}}}",
        model: model,
        timeout: timeout
    )
}

private func chatCompletionJSON(content: String, promptTokens: Int = 10, completionTokens: Int = 5, cachedTokens: Int? = nil, model: String? = nil) -> Data {
    var usage: [String: Any] = ["prompt_tokens": promptTokens, "completion_tokens": completionTokens]
    if let cachedTokens {
        usage["prompt_tokens_details"] = ["cached_tokens": cachedTokens]
    }
    var json: [String: Any] = [
        "choices": [["message": ["role": "assistant", "content": content]]],
        "usage": usage
    ]
    if let model {
        json["model"] = model
    }
    return try! JSONSerialization.data(withJSONObject: json)
}

/// Layer 1 coverage for `OpenAIChatBackend` (`docs/design/14-llm-provider.md` section 4/6): pure
/// URL/header/body assembly and response parsing, plus `complete(_:)` wired to a `FakeHTTPTransport`.
@Suite("OpenAIChatBackend")
struct OpenAIChatBackendTests {
    // MARK: - URL assembly (section 4.1)

    @Test("buildURL normalizes a trailing slash on base_url")
    func buildURLNormalizesTrailingSlash() {
        let url = OpenAIChatBackend.buildURL(baseURL: "https://api.openai.com/v1/", apiVersion: "")
        #expect(url?.absoluteString == "https://api.openai.com/v1/chat/completions")
    }

    @Test("buildURL normalizes multiple trailing slashes on base_url")
    func buildURLNormalizesMultipleTrailingSlashes() {
        let url = OpenAIChatBackend.buildURL(baseURL: "https://api.openai.com/v1//", apiVersion: "")
        #expect(url?.absoluteString == "https://api.openai.com/v1/chat/completions")
    }

    @Test("buildURL appends ?api-version= when apiVersion is non-empty")
    func buildURLAppendsAPIVersion() {
        let url = OpenAIChatBackend.buildURL(baseURL: "https://res.openai.azure.com/openai/deployments/dep", apiVersion: "2024-06-01")
        #expect(url?.absoluteString == "https://res.openai.azure.com/openai/deployments/dep/chat/completions?api-version=2024-06-01")
    }

    @Test("buildURL omits the query string when apiVersion is empty")
    func buildURLOmitsAPIVersionWhenEmpty() {
        let url = OpenAIChatBackend.buildURL(baseURL: "https://api.openai.com/v1", apiVersion: "")
        #expect(url?.absoluteString == "https://api.openai.com/v1/chat/completions")
    }

    @Test("buildURL returns nil for an empty base_url")
    func buildURLReturnsNilForEmptyBaseURL() {
        #expect(OpenAIChatBackend.buildURL(baseURL: "", apiVersion: "") == nil)
    }

    // MARK: - Auth header resolution (section 3/4.1)

    @Test("resolveAuthHeaderKind returns bearer when auth_header is explicitly \"bearer\"")
    func authHeaderExplicitBearer() {
        #expect(OpenAIChatBackend.resolveAuthHeaderKind(authHeader: "bearer", apiVersion: "2024-06-01") == .bearer)
    }

    @Test("resolveAuthHeaderKind returns apiKey when auth_header is explicitly \"api-key\"")
    func authHeaderExplicitAPIKey() {
        #expect(OpenAIChatBackend.resolveAuthHeaderKind(authHeader: "api-key", apiVersion: "") == .apiKey)
    }

    @Test("resolveAuthHeaderKind derives apiKey from a non-empty api_version when unset")
    func authHeaderDerivedFromAPIVersion() {
        #expect(OpenAIChatBackend.resolveAuthHeaderKind(authHeader: "", apiVersion: "2024-06-01") == .apiKey)
    }

    @Test("resolveAuthHeaderKind derives bearer from an empty api_version when unset")
    func authHeaderDerivedBearerWhenNoAPIVersion() {
        #expect(OpenAIChatBackend.resolveAuthHeaderKind(authHeader: "", apiVersion: "") == .bearer)
    }

    // MARK: - API key resolution (`docs/design/26-settings-ui.md` §3.2)

    @Test("resolveAPIKey prefers a non-empty Keychain value over api_key/api_key_env")
    func resolveAPIKeyPrefersKeychain() throws {
        let config = makeConfig(apiKey: "direct-key", apiKeyEnv: "OPENAI_API_KEY")
        let credentialStore = InMemoryCredentialStore()
        try credentialStore.write("keychain-key", account: CredentialAccount.openAIAPIKey)
        let key = OpenAIChatBackend.resolveAPIKey(config: config, environment: ["OPENAI_API_KEY": "env-key"], credentialStore: credentialStore)
        #expect(key == "keychain-key")
    }

    @Test("resolveAPIKey prefers a non-empty api_key over api_key_env when Keychain is empty")
    func resolveAPIKeyPrefersDirectKey() throws {
        let config = makeConfig(apiKey: "direct-key", apiKeyEnv: "OPENAI_API_KEY")
        let key = OpenAIChatBackend.resolveAPIKey(config: config, environment: ["OPENAI_API_KEY": "env-key"], credentialStore: InMemoryCredentialStore())
        #expect(key == "direct-key")
    }

    @Test("resolveAPIKey falls back to api_key_env when Keychain and api_key are both empty")
    func resolveAPIKeyFallsBackToEnv() throws {
        let config = makeConfig(apiKey: "", apiKeyEnv: "OPENAI_API_KEY")
        let key = OpenAIChatBackend.resolveAPIKey(config: config, environment: ["OPENAI_API_KEY": "env-key"], credentialStore: InMemoryCredentialStore())
        #expect(key == "env-key")
    }

    @Test("resolveAPIKey returns nil when Keychain, api_key, and api_key_env all resolve empty")
    func resolveAPIKeyThrowsMissingAPIKey() throws {
        let config = makeConfig(apiKey: "", apiKeyEnv: "")
        let key = OpenAIChatBackend.resolveAPIKey(config: config, environment: [:], credentialStore: InMemoryCredentialStore())
        #expect(key == nil)
    }

    @Test("resolveAPIKey returns nil when api_key_env names an unset environment variable")
    func resolveAPIKeyThrowsMissingAPIKeyForUnsetEnv() throws {
        let config = makeConfig(apiKey: "", apiKeyEnv: "OPENAI_API_KEY")
        let key = OpenAIChatBackend.resolveAPIKey(config: config, environment: [:], credentialStore: InMemoryCredentialStore())
        #expect(key == nil)
    }

    // MARK: - Model resolution (section 3)

    @Test("resolveModel uses llm.openai.model when non-empty, ignoring the request's model")
    func resolveModelPrefersConfigOverride() {
        let config = makeConfig(model: "gpt-4o-deployment")
        #expect(OpenAIChatBackend.resolveModel(config: config, requestModel: "claude-haiku-4-5-20251001") == "gpt-4o-deployment")
    }

    @Test("resolveModel falls back to the request's model when llm.openai.model is empty")
    func resolveModelFallsBackToRequestModel() {
        let config = makeConfig(model: "")
        #expect(OpenAIChatBackend.resolveModel(config: config, requestModel: "gpt-4o-mini") == "gpt-4o-mini")
    }

    // MARK: - Request body assembly (section 4.1)

    @Test("buildURLRequest sets the Authorization bearer header and a json_schema response_format body")
    func buildURLRequestBearerAndBody() throws {
        let config = makeConfig()
        let request = makeChatRequest()
        let urlRequest = try OpenAIChatBackend.buildURLRequest(request: request, config: config, apiKey: "sk-test")

        #expect(urlRequest.httpMethod == "POST")
        #expect(urlRequest.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(urlRequest.value(forHTTPHeaderField: "api-key") == nil)
        #expect(urlRequest.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let body = try #require(urlRequest.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "gpt-4o-mini")

        let messages = try #require(json["messages"] as? [[String: String]])
        #expect(messages == [
            ["role": "system", "content": "system prompt"],
            ["role": "user", "content": "user prompt"]
        ])

        let responseFormat = try #require(json["response_format"] as? [String: Any])
        #expect(responseFormat["type"] as? String == "json_schema")
        let jsonSchema = try #require(responseFormat["json_schema"] as? [String: Any])
        #expect(jsonSchema["name"] as? String == "response")
        #expect(jsonSchema["strict"] as? Bool == false)
        let schema = try #require(jsonSchema["schema"] as? [String: Any])
        #expect(schema["type"] as? String == "object")
    }

    @Test("buildURLRequest sets the api-key header (not Authorization) when auth_header derives to api-key")
    func buildURLRequestAPIKeyHeader() throws {
        let config = makeConfig(apiVersion: "2024-06-01")
        let urlRequest = try OpenAIChatBackend.buildURLRequest(request: makeChatRequest(), config: config, apiKey: "sk-test")

        #expect(urlRequest.value(forHTTPHeaderField: "api-key") == "sk-test")
        #expect(urlRequest.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("buildURLRequest overrides the body's model with llm.openai.model when set")
    func buildURLRequestModelOverride() throws {
        let config = makeConfig(model: "gpt-4o-deployment")
        let urlRequest = try OpenAIChatBackend.buildURLRequest(request: makeChatRequest(model: "claude-haiku-4-5-20251001"), config: config, apiKey: "sk-test")

        let body = try #require(urlRequest.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "gpt-4o-deployment")
    }

    @Test("buildURLRequest sets timeoutInterval from request.timeout")
    func buildURLRequestSetsTimeout() throws {
        let urlRequest = try OpenAIChatBackend.buildURLRequest(request: makeChatRequest(timeout: .seconds(45)), config: makeConfig(), apiKey: "sk-test")
        #expect(urlRequest.timeoutInterval == 45)
    }

    @Test("buildURLRequest throws invalidJSON when the schema string is not valid JSON")
    func buildURLRequestThrowsInvalidJSONForBadSchema() throws {
        var request = makeChatRequest()
        request.schema = "not json"
        #expect(throws: LLMClientError.invalidJSON(raw: "not json")) {
            _ = try OpenAIChatBackend.buildURLRequest(request: request, config: makeConfig(), apiKey: "sk-test")
        }
    }

    @Test("buildURLRequest throws networkFailed for an invalid base_url")
    func buildURLRequestThrowsNetworkFailedForInvalidBaseURL() throws {
        #expect(throws: LLMClientError.self) {
            _ = try OpenAIChatBackend.buildURLRequest(request: makeChatRequest(), config: makeConfig(baseURL: ""), apiKey: "sk-test")
        }
    }

    // MARK: - Response parsing (section 4.2)

    @Test("parseResponse extracts structuredJSON and usage from a well-formed chat completion")
    func parseResponseWellFormed() throws {
        let data = chatCompletionJSON(content: "{\"title\":\"hello\"}", promptTokens: 12, completionTokens: 4, cachedTokens: 3)
        let response = HTTPURLResponse(url: URL(string: "https://api.openai.com/v1/chat/completions")!, statusCode: 200, httpVersion: nil, headerFields: nil)!

        let result = try OpenAIChatBackend.parseResponse(data: data, httpResponse: response, config: makeConfig(), requestModel: "claude-haiku-4-5-20251001")

        #expect(String(data: result.structuredJSON, encoding: .utf8) == "{\"title\":\"hello\"}")
        // `docs/design/16-llm-usage-stats.md` section 2: `inputTokens` is normalized to *exclude*
        // `cached_tokens` (12 prompt_tokens - 3 cached_tokens = 9), unlike OpenAI's raw
        // `prompt_tokens` which includes them.
        #expect(result.usage == LLMUsage(inputTokens: 9, outputTokens: 4, cacheReadInputTokens: 3, cacheCreationInputTokens: 0, totalCostUSD: 0))
    }

    @Test("parseResponse subtracts cached_tokens from prompt_tokens even when cached_tokens equals prompt_tokens")
    func parseResponseFullyCachedPromptYieldsZeroInputTokens() throws {
        let data = chatCompletionJSON(content: "{\"title\":\"hello\"}", promptTokens: 10, completionTokens: 2, cachedTokens: 10)
        let response = HTTPURLResponse(url: URL(string: "https://api.openai.com/v1/chat/completions")!, statusCode: 200, httpVersion: nil, headerFields: nil)!

        let result = try OpenAIChatBackend.parseResponse(data: data, httpResponse: response, config: makeConfig(), requestModel: "claude-haiku-4-5-20251001")
        #expect(result.usage.inputTokens == 0)
        #expect(result.usage.cacheReadInputTokens == 10)
    }

    @Test("parseResponse defaults usage to zero when the usage field is missing")
    func parseResponseMissingUsageDefaultsToZero() throws {
        let json: [String: Any] = ["choices": [["message": ["content": "{\"title\":\"hi\"}"]]]]
        let data = try JSONSerialization.data(withJSONObject: json)
        let response = HTTPURLResponse(url: URL(string: "https://api.openai.com/v1/chat/completions")!, statusCode: 200, httpVersion: nil, headerFields: nil)!

        let result = try OpenAIChatBackend.parseResponse(data: data, httpResponse: response, config: makeConfig(), requestModel: "claude-haiku-4-5-20251001")
        #expect(result.usage == .zero)
    }

    @Test("parseResponse throws missingStructuredOutput when content is missing")
    func parseResponseMissingContentThrowsMissingStructuredOutput() throws {
        let json: [String: Any] = ["choices": [["message": ["role": "assistant"]]]]
        let data = try JSONSerialization.data(withJSONObject: json)
        let response = HTTPURLResponse(url: URL(string: "https://api.openai.com/v1/chat/completions")!, statusCode: 200, httpVersion: nil, headerFields: nil)!

        #expect(throws: LLMClientError.self) {
            _ = try OpenAIChatBackend.parseResponse(data: data, httpResponse: response, config: makeConfig(), requestModel: "claude-haiku-4-5-20251001")
        }
    }

    @Test("parseResponse throws missingStructuredOutput when content is empty")
    func parseResponseEmptyContentThrowsMissingStructuredOutput() throws {
        let data = chatCompletionJSON(content: "")
        let response = HTTPURLResponse(url: URL(string: "https://api.openai.com/v1/chat/completions")!, statusCode: 200, httpVersion: nil, headerFields: nil)!

        #expect(throws: LLMClientError.self) {
            _ = try OpenAIChatBackend.parseResponse(data: data, httpResponse: response, config: makeConfig(), requestModel: "claude-haiku-4-5-20251001")
        }
    }

    @Test("parseResponse throws notAuthenticated on HTTP 401")
    func parseResponse401ThrowsNotAuthenticated() throws {
        let response = HTTPURLResponse(url: URL(string: "https://api.openai.com/v1/chat/completions")!, statusCode: 401, httpVersion: nil, headerFields: nil)!
        #expect(throws: LLMClientError.notAuthenticated) {
            _ = try OpenAIChatBackend.parseResponse(data: Data(), httpResponse: response, config: makeConfig(), requestModel: "claude-haiku-4-5-20251001")
        }
    }

    @Test("parseResponse throws notAuthenticated on HTTP 403")
    func parseResponse403ThrowsNotAuthenticated() throws {
        let response = HTTPURLResponse(url: URL(string: "https://api.openai.com/v1/chat/completions")!, statusCode: 403, httpVersion: nil, headerFields: nil)!
        #expect(throws: LLMClientError.notAuthenticated) {
            _ = try OpenAIChatBackend.parseResponse(data: Data(), httpResponse: response, config: makeConfig(), requestModel: "claude-haiku-4-5-20251001")
        }
    }

    @Test("parseResponse throws httpFailed with a truncated body on HTTP 500")
    func parseResponse500ThrowsHTTPFailed() throws {
        let body = "internal server error".data(using: .utf8)!
        let response = HTTPURLResponse(url: URL(string: "https://api.openai.com/v1/chat/completions")!, statusCode: 500, httpVersion: nil, headerFields: nil)!

        #expect(throws: LLMClientError.httpFailed(status: 500, body: "internal server error")) {
            _ = try OpenAIChatBackend.parseResponse(data: body, httpResponse: response, config: makeConfig(), requestModel: "claude-haiku-4-5-20251001")
        }
    }

    @Test("parseResponse truncates an oversized error body to 1KB")
    func parseResponseTruncatesOversizedErrorBody() throws {
        let hugeBody = String(repeating: "x", count: 5_000).data(using: .utf8)!
        let response = HTTPURLResponse(url: URL(string: "https://api.openai.com/v1/chat/completions")!, statusCode: 500, httpVersion: nil, headerFields: nil)!

        do {
            _ = try OpenAIChatBackend.parseResponse(data: hugeBody, httpResponse: response, config: makeConfig(), requestModel: "claude-haiku-4-5-20251001")
            Issue.record("expected httpFailed to be thrown")
        } catch LLMClientError.httpFailed(let status, let body) {
            #expect(status == 500)
            #expect(body.utf8.count == 1_024)
        }
    }

    // MARK: - Responded-model resolution (section 2 of docs/design/16-llm-usage-stats.md)

    @Test("parseResponse records the response body's model field as respondedModel")
    func parseResponseRecordsResponseModel() throws {
        // The Azure legacy deployment scenario this bug report is about: base_url embeds the
        // deployment name, llm.openai.model is left empty, and the request body's "model" is
        // whatever `refinement.model`/`summary.model` happens to default to -- but Azure answers
        // with the real underlying model in the response body, which must win.
        let config = makeConfig(baseURL: "https://res.openai.azure.com/openai/deployments/gpt-5.4-nano", model: "")
        let data = chatCompletionJSON(content: "{\"title\":\"hello\"}", model: "gpt-5.4-nano")
        let response = HTTPURLResponse(url: URL(string: "https://res.openai.azure.com/openai/deployments/gpt-5.4-nano/chat/completions")!, statusCode: 200, httpVersion: nil, headerFields: nil)!

        let result = try OpenAIChatBackend.parseResponse(data: data, httpResponse: response, config: config, requestModel: "claude-haiku-4-5-20251001")

        #expect(result.respondedModel == "gpt-5.4-nano")
    }

    @Test("parseResponse falls back to llm.openai.model when the response has no model field")
    func parseResponseFallsBackToConfigModelWhenResponseModelMissing() throws {
        let config = makeConfig(model: "gpt-4o-deployment")
        let data = chatCompletionJSON(content: "{\"title\":\"hello\"}")
        let response = HTTPURLResponse(url: URL(string: "https://api.openai.com/v1/chat/completions")!, statusCode: 200, httpVersion: nil, headerFields: nil)!

        let result = try OpenAIChatBackend.parseResponse(data: data, httpResponse: response, config: config, requestModel: "claude-haiku-4-5-20251001")

        #expect(result.respondedModel == "gpt-4o-deployment")
    }

    @Test("parseResponse falls back to the base_url deployment name when the response and config have no model")
    func parseResponseFallsBackToDeploymentNameWhenResponseAndConfigModelMissing() throws {
        let config = makeConfig(baseURL: "https://res.openai.azure.com/openai/deployments/gpt-5.4-nano", model: "")
        let data = chatCompletionJSON(content: "{\"title\":\"hello\"}")
        let response = HTTPURLResponse(url: URL(string: "https://res.openai.azure.com/openai/deployments/gpt-5.4-nano/chat/completions")!, statusCode: 200, httpVersion: nil, headerFields: nil)!

        let result = try OpenAIChatBackend.parseResponse(data: data, httpResponse: response, config: config, requestModel: "claude-haiku-4-5-20251001")

        #expect(result.respondedModel == "gpt-5.4-nano")
    }

    @Test("parseResponse falls back to requestModel when nothing else resolves a model")
    func parseResponseFallsBackToRequestModelAsLastResort() throws {
        let config = makeConfig(baseURL: "https://api.openai.com/v1", model: "")
        let data = chatCompletionJSON(content: "{\"title\":\"hello\"}")
        let response = HTTPURLResponse(url: URL(string: "https://api.openai.com/v1/chat/completions")!, statusCode: 200, httpVersion: nil, headerFields: nil)!

        let result = try OpenAIChatBackend.parseResponse(data: data, httpResponse: response, config: config, requestModel: "claude-haiku-4-5-20251001")

        #expect(result.respondedModel == "claude-haiku-4-5-20251001")
    }

    @Test("resolveRespondedModel prefers a non-empty response model over every fallback")
    func resolveRespondedModelPrefersResponseModel() {
        let config = makeConfig(baseURL: "https://res.openai.azure.com/openai/deployments/other-model", model: "gpt-4o-deployment")
        let resolved = OpenAIChatBackend.resolveRespondedModel(rawResponseModel: "gpt-5.4-nano", config: config, requestModel: "claude-haiku-4-5-20251001")
        #expect(resolved == "gpt-5.4-nano")
    }

    @Test("resolveRespondedModel ignores an empty response model string")
    func resolveRespondedModelIgnoresEmptyResponseModel() {
        let config = makeConfig(model: "gpt-4o-deployment")
        let resolved = OpenAIChatBackend.resolveRespondedModel(rawResponseModel: "", config: config, requestModel: "claude-haiku-4-5-20251001")
        #expect(resolved == "gpt-4o-deployment")
    }

    @Test("extractDeploymentName extracts the deployment name from an Azure legacy base_url")
    func extractDeploymentNameExtractsFromLegacyURL() {
        #expect(OpenAIChatBackend.extractDeploymentName(baseURL: "https://res.openai.azure.com/openai/deployments/gpt-5.4-nano") == "gpt-5.4-nano")
    }

    @Test("extractDeploymentName stops at a trailing slash after the deployment name")
    func extractDeploymentNameStopsAtTrailingSlash() {
        #expect(OpenAIChatBackend.extractDeploymentName(baseURL: "https://res.openai.azure.com/openai/deployments/gpt-5.4-nano/") == "gpt-5.4-nano")
    }

    @Test("extractDeploymentName returns nil for a non-Azure-legacy base_url")
    func extractDeploymentNameReturnsNilForNonLegacyURL() {
        #expect(OpenAIChatBackend.extractDeploymentName(baseURL: "https://api.openai.com/v1") == nil)
    }

    @Test("extractDeploymentName returns nil when the deployments segment has no name")
    func extractDeploymentNameReturnsNilForEmptyName() {
        #expect(OpenAIChatBackend.extractDeploymentName(baseURL: "https://res.openai.azure.com/openai/deployments/") == nil)
    }

    // MARK: - complete(_:) via FakeHTTPTransport

    @Test("complete(_:) sends one request and returns the parsed response")
    func completeSendsRequestAndReturnsParsedResponse() async throws {
        let transport = FakeHTTPTransport(dataToReturn: chatCompletionJSON(content: "{\"title\":\"hello\"}", model: "gpt-5.4-nano"))
        let backend = makeBackend(config: makeConfig(), transport: transport)

        let response = try await backend.complete(makeChatRequest())

        #expect(String(data: response.structuredJSON, encoding: .utf8) == "{\"title\":\"hello\"}")
        // `complete(_:)` wires the response body's model through to `respondedModel`, the same as
        // `parseResponse` alone (`resolveRespondedModel`'s fallback chain).
        #expect(response.respondedModel == "gpt-5.4-nano")
        #expect(await transport.callCount == 1)
    }

    @Test("complete(_:) throws missingAPIKey without sending a request when no API key resolves")
    func completeThrowsMissingAPIKeyWithoutSendingRequest() async throws {
        let transport = FakeHTTPTransport()
        let backend = makeBackend(config: makeConfig(apiKey: "", apiKeyEnv: ""), transport: transport)

        await #expect(throws: LLMClientError.missingAPIKey) {
            _ = try await backend.complete(makeChatRequest())
        }
        #expect(await transport.callCount == 0)
    }

    @Test("complete(_:) maps a timed-out URLError to timedOut(request.timeout)")
    func completeMapsTimedOutURLError() async throws {
        let transport = FakeHTTPTransport(errorToThrow: URLError(.timedOut))
        let backend = makeBackend(config: makeConfig(), transport: transport)

        await #expect(throws: LLMClientError.timedOut(.seconds(30))) {
            _ = try await backend.complete(makeChatRequest(timeout: .seconds(30)))
        }
    }

    @Test("complete(_:) maps a non-timeout transport error to networkFailed")
    func completeMapsOtherTransportErrorsToNetworkFailed() async throws {
        let transport = FakeHTTPTransport(errorToThrow: URLError(.notConnectedToInternet))
        let backend = makeBackend(config: makeConfig(), transport: transport)

        do {
            _ = try await backend.complete(makeChatRequest())
            Issue.record("expected networkFailed to be thrown")
        } catch LLMClientError.networkFailed {
            // expected
        }
    }
}
