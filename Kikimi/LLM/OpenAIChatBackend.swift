import Foundation
import OSLog

// MARK: - HTTPTransporting

/// Abstracts the HTTP layer so `OpenAIChatBackend` can be unit-tested without a real network call
/// (`docs/design/14-llm-provider.md` section 4.3), the same DI pattern `LLMProcessRunner` uses for the
/// `claude` CLI subprocess.
protocol HTTPTransporting: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

// MARK: - URLSessionHTTPTransport

/// Production `HTTPTransporting`: a thin `URLSession` wrapper.
struct URLSessionHTTPTransport: HTTPTransporting {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMClientError.networkFailed(description: "response was not an HTTP response: \(response)")
        }
        return (data, httpResponse)
    }
}

// MARK: - LazyAPIKey

/// Memoizes one optional API-key resolution. A reference type so the enclosing `Sendable` struct can
/// cache into it, and double-`Optional` internally so "resolved to nil" is distinguished from
/// "not yet resolved" -- a missing key must not be re-resolved (and re-read from the credential
/// store) on every `complete(_:)`.
private final class LazyAPIKey: @unchecked Sendable {
    private let resolve: @Sendable () -> String?
    private let lock = NSLock()
    private var cached: String??

    init(resolve: @escaping @Sendable () -> String?) {
        self.resolve = resolve
    }

    func value() -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let cached {
            return cached
        }
        let resolved = resolve()
        cached = .some(resolved)
        return resolved
    }
}

// MARK: - OpenAIChatBackend

/// `LLMBackend` for OpenAI-compatible chat completions over HTTP (`docs/design/14-llm-provider.md`
/// section 4), primarily targeting Azure OpenAI. URL/header/body assembly and response parsing are
/// `static` pure functions (section 4.3) so they are directly unit-testable without `transport` at
/// all, mirroring `ClaudeCLIBackend.buildArguments`/`decodeEnvelope`.
struct OpenAIChatBackend: LLMBackend {
    /// `llm.providers` key this backend was built for (`docs/design/44-llm-model-config.md` §5.2/§6).
    /// Only used to resolve the API key's credential account (`CredentialAccount.providerAPIKey(name:)`)
    /// and to gate the legacy-migration step (§6 step 2: name `"openai"` only).
    private let providerName: String
    private let config: OpenAIBackendConfig
    private let transport: HTTPTransporting
    /// Resolved at most once per backend, on the first `complete(_:)` -- never in `init`. Eagerly
    /// resolving would make merely *constructing* a backend read the credential store, which is a
    /// real side effect: it can trigger the Keychain-to-Secure-Enclave migration and its one-time OS
    /// dialog (`docs/design/35-secure-enclave-credentials.md` §4). `LLMClient` builds registry
    /// backends lazily but still at a point construction must stay pure -- unit tests reach `init`
    /// directly too. `nil` means no key resolved anywhere in the precedence chain; `complete(_:)`
    /// throws `.missingAPIKey` off that cached `nil` without re-reading on every call
    /// (`docs/design/26-settings-ui.md` §3.2, `docs/design/44-llm-model-config.md` §6).
    private let apiKeySource: LazyAPIKey

    init(
        providerName: String,
        config: OpenAIBackendConfig,
        transport: HTTPTransporting = URLSessionHTTPTransport(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        credentialStore: CredentialStoring = DefaultCredentialStore.shared
    ) {
        self.providerName = providerName
        self.config = config
        self.transport = transport
        self.apiKeySource = LazyAPIKey {
            Self.resolveAPIKey(providerName: providerName, config: config, environment: environment, credentialStore: credentialStore)
        }
    }

    // MARK: - LLMBackend

    func complete(_ request: LLMRequest) async throws -> LLMBackendResponse {
        guard let apiKey = apiKeySource.value() else {
            throw LLMClientError.missingAPIKey
        }
        let urlRequest = try Self.buildURLRequest(request: request, config: config, apiKey: apiKey)

        let data: Data
        let httpResponse: HTTPURLResponse
        do {
            (data, httpResponse) = try await transport.send(urlRequest)
        } catch let error as LLMClientError {
            throw error
        } catch let urlError as URLError where urlError.code == .timedOut {
            throw LLMClientError.timedOut(request.timeout)
        } catch {
            throw LLMClientError.networkFailed(description: String(describing: error))
        }

        return try Self.parseResponse(data: data, httpResponse: httpResponse, config: config, requestModel: request.model)
    }

    // MARK: - API key resolution (`docs/design/44-llm-model-config.md` §6: "API キー解決順")

    private static let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "OpenAIChatBackend")

    /// Precedence chain (§6): the per-provider credential-store account
    /// (`CredentialAccount.providerAPIKey(name:)`) -> a one-time legacy migration from the pre-44-章
    /// single-provider account (`CredentialAccount.openAIAPIKey`), gated to providers literally named
    /// `"openai"` (§4's migration always uses that name for a migrated `openai`-kind provider) ->
    /// `config.apiKey` (config.yaml plaintext, back-compat fallback) -> `api_key_env` environment
    /// variable -> `nil`.
    ///
    /// `throws` is dropped in favor of `Optional` because the sole caller runs inside `LazyAPIKey`,
    /// which cannot propagate a thrown error -- `complete(_:)` throws `.missingAPIKey` off the cached
    /// `nil` result instead (see `apiKeySource`'s doc comment). The migration step does have a side
    /// effect (a credential-store write + delete), unlike every other step here, but it only ever
    /// runs once per backend lifetime (this function itself is only ever invoked once, memoized by
    /// `LazyAPIKey`).
    static func resolveAPIKey(
        providerName: String,
        config: OpenAIBackendConfig,
        environment: [String: String],
        credentialStore: CredentialStoring
    ) -> String? {
        let newAccount = CredentialAccount.providerAPIKey(name: providerName)
        if let storedValue = credentialStore.read(account: newAccount), !storedValue.isEmpty {
            return storedValue
        }
        if providerName == "openai", let migrated = migrateLegacyAPIKey(newAccount: newAccount, credentialStore: credentialStore) {
            return migrated
        }
        if !config.apiKey.isEmpty {
            return config.apiKey
        }
        if !config.apiKeyEnv.isEmpty, let envValue = environment[config.apiKeyEnv], !envValue.isEmpty {
            return envValue
        }
        return nil
    }

    /// §6 step 2: "コピー → 削除、失敗は次回リトライ" -- the same pattern
    /// `EncryptedFileCredentialStore.migrateFromLegacyStore` uses for its own Keychain migration, one
    /// layer up (that one moves *store implementations*; this one moves *accounts* within whichever
    /// store is configured). A write failure keeps the legacy account intact and returns the value
    /// anyway, so this call still succeeds and simply retries the copy on the next resolution.
    private static func migrateLegacyAPIKey(newAccount: String, credentialStore: CredentialStoring) -> String? {
        guard let legacyValue = credentialStore.read(account: CredentialAccount.openAIAPIKey), !legacyValue.isEmpty else {
            return nil
        }
        do {
            try credentialStore.write(legacyValue, account: newAccount)
        } catch {
            logger.error(
                "Failed to migrate \(CredentialAccount.openAIAPIKey, privacy: .public) to \(newAccount, privacy: .public); will retry: \(error, privacy: .public)"
            )
            return legacyValue
        }
        do {
            try credentialStore.delete(account: CredentialAccount.openAIAPIKey)
            logger.info("Migrated \(CredentialAccount.openAIAPIKey, privacy: .public) to \(newAccount, privacy: .public)")
        } catch {
            logger.warning(
                "Migrated \(CredentialAccount.openAIAPIKey, privacy: .public) to \(newAccount, privacy: .public) but could not remove the stale legacy entry: \(error, privacy: .public)"
            )
        }
        return legacyValue
    }

    // MARK: - Model resolution (section 3: "モデル解決")

    static func resolveModel(config: OpenAIBackendConfig, requestModel: String) -> String {
        config.model.isEmpty ? requestModel : config.model
    }

    // MARK: - Responded-model resolution (`docs/design/16-llm-usage-stats.md` section 2)

    /// Resolves the model name to persist for usage/refinement bookkeeping. The response body's own
    /// `model` field is the most authoritative source: for an Azure "legacy" deployment URL
    /// (`.../openai/deployments/<name>`), Azure ignores the request body's `model` and picks the model
    /// from the deployment name in the URL instead, so `rawResponseModel` is the only place the real
    /// answering model shows up. Falls back through the same precedence `resolveModel`/`buildURL` used
    /// to build the request in the first place, for the edge case where a response has no `model`
    /// field at all: `llm.openai.model` (non-empty) -> the deployment name extracted from `base_url` ->
    /// `requestModel` (matches `resolveModel`'s own fallback, so a caller with no better signal ends up
    /// recording exactly what `resolveModel` sent).
    static func resolveRespondedModel(rawResponseModel: String?, config: OpenAIBackendConfig, requestModel: String) -> String {
        if let rawResponseModel, !rawResponseModel.isEmpty {
            return rawResponseModel
        }
        if !config.model.isEmpty {
            return config.model
        }
        if let deploymentName = extractDeploymentName(baseURL: config.baseURL) {
            return deploymentName
        }
        return requestModel
    }

    /// Extracts the deployment name from an Azure "legacy" `base_url`
    /// (`.../openai/deployments/<name>`, section 3's Azure legacy example). Returns `nil` when
    /// `base_url` has no `/deployments/` segment, or the segment right after it is empty.
    static func extractDeploymentName(baseURL: String) -> String? {
        guard let range = baseURL.range(of: "/deployments/") else {
            return nil
        }
        let remainder = baseURL[range.upperBound...]
        let name = remainder.prefix { $0 != "/" && $0 != "?" }
        return name.isEmpty ? nil : String(name)
    }

    // MARK: - URL / auth-header assembly (section 4.1)

    /// Normalizes `base_url`'s trailing slash and appends `/chat/completions`, plus `?api-version=`
    /// when `apiVersion` is non-empty (section 4.1's Azure-legacy form).
    static func buildURL(baseURL: String, apiVersion: String) -> URL? {
        var normalizedBase = baseURL
        while normalizedBase.hasSuffix("/") {
            normalizedBase.removeLast()
        }
        guard !normalizedBase.isEmpty else { return nil }

        guard var components = URLComponents(string: normalizedBase + "/chat/completions") else {
            return nil
        }
        if !apiVersion.isEmpty {
            components.queryItems = [URLQueryItem(name: "api-version", value: apiVersion)]
        }
        return components.url
    }

    enum AuthHeaderKind: Equatable {
        case bearer
        case apiKey
    }

    /// `auth_header` config resolution (section 3): explicit `"bearer"`/`"api-key"` wins; otherwise
    /// derived from whether `api_version` is set (non-empty → Azure-legacy `api-key`, empty →
    /// `bearer`).
    static func resolveAuthHeaderKind(authHeader: String, apiVersion: String) -> AuthHeaderKind {
        switch authHeader {
        case "bearer":
            return .bearer
        case "api-key":
            return .apiKey
        default:
            return apiVersion.isEmpty ? .bearer : .apiKey
        }
    }

    // MARK: - reasoning_effort resolution (`docs/design/44-llm-model-config.md` §5.3)

    /// `request.params.effort` (per-call, from an `llm.models` alias) wins when non-nil and
    /// non-empty; otherwise the provider config's own `reasoning_effort` default (non-empty); `nil`
    /// omits the field from the request body entirely.
    static func resolveReasoningEffort(paramsEffort: String?, providerReasoningEffort: String) -> String? {
        if let paramsEffort, !paramsEffort.isEmpty {
            return paramsEffort
        }
        return providerReasoningEffort.isEmpty ? nil : providerReasoningEffort
    }

    // MARK: - Request body assembly (section 4.1)

    /// `[system] + request.messages + [user]` (38-session-chat.md §4.1). Unlike `ClaudeCLIBackend`,
    /// this endpoint takes turn arrays natively, so prior turns are passed through with their own
    /// roles rather than flattened -- which is the whole reason `LLMRequest.messages` is structured
    /// (CH15: past answers reach the model as the *assistant's* words, not the user's).
    ///
    /// With `messages == nil` this produces exactly the two-message body every pre-chat consumer
    /// already sent.
    static func buildMessages(request: LLMRequest) -> [[String: String]] {
        var messages: [[String: String]] = [["role": "system", "content": request.system]]
        for message in request.messages ?? [] {
            messages.append(["role": message.role.rawValue, "content": message.text])
        }
        messages.append(["role": "user", "content": request.user])
        return messages
    }

    static func buildURLRequest(request: LLMRequest, config: OpenAIBackendConfig, apiKey: String) throws -> URLRequest {
        guard let url = buildURL(baseURL: config.baseURL, apiVersion: config.apiVersion) else {
            throw LLMClientError.networkFailed(description: "llm.openai.base_url is missing or invalid: \"\(config.baseURL)\"")
        }
        guard let schemaData = request.schema.data(using: .utf8),
              let schemaObject = try? JSONSerialization.jsonObject(with: schemaData)
        else {
            throw LLMClientError.invalidJSON(raw: request.schema)
        }

        var body: [String: Any] = [
            "model": resolveModel(config: config, requestModel: request.model),
            "messages": buildMessages(request: request),
            "response_format": [
                "type": "json_schema",
                "json_schema": [
                    "name": "response",
                    // Fixed per section 4.1: existing consumer schemas (refinement / summary) aren't
                    // guaranteed to satisfy strict mode's `additionalProperties: false` + all-required
                    // constraint. A schema mismatch still safely falls back to `decodeFailed`.
                    "strict": false,
                    "schema": schemaObject
                ]
            ]
        ]
        // `reasoning_effort` is sent only when it resolves to a non-empty value (section 4.1):
        // non-reasoning models (`gpt-4.1-mini` etc.) reject the field entirely.
        // `docs/design/44-llm-model-config.md` §5.3 extends the old "config value only" behavior to a
        // 2-stage resolution: the per-call `request.params.effort` (an `llm.models` alias's own
        // `effort`, §3.3) wins when set, otherwise the provider's own `reasoning_effort` default is
        // used, otherwise the field is omitted. gpt-5-series reasoning models take
        // `"none"`/`"minimal"`/.../`"xhigh"` to trade latency and thinking-token cost against quality.
        if let effort = resolveReasoningEffort(paramsEffort: request.params.effort, providerReasoningEffort: config.reasoningEffort) {
            body["reasoning_effort"] = effort
        }
        let bodyData = try JSONSerialization.data(withJSONObject: body)

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = bodyData
        urlRequest.timeoutInterval = request.timeout.timeInterval
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        switch resolveAuthHeaderKind(authHeader: config.authHeader, apiVersion: config.apiVersion) {
        case .bearer:
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .apiKey:
            urlRequest.setValue(apiKey, forHTTPHeaderField: "api-key")
        }
        return urlRequest
    }

    // MARK: - Response parsing (section 4.2)

    /// Byte cap for error/malformed-response bodies retained in thrown errors (section 4.2's "body
    /// は先頭 1KB に切り詰め").
    private static let errorBodyByteLimit = 1_024

    static func parseResponse(data: Data, httpResponse: HTTPURLResponse, config: OpenAIBackendConfig, requestModel: String) throws -> LLMBackendResponse {
        guard (200...299).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw LLMClientError.notAuthenticated
            }
            throw LLMClientError.httpFailed(status: httpResponse.statusCode, body: truncatedBody(data))
        }

        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String,
              !content.isEmpty,
              let contentData = content.data(using: .utf8)
        else {
            throw LLMClientError.missingStructuredOutput(raw: truncatedBody(data))
        }

        let usageDict = (json["usage"] as? [String: Any]) ?? [:]
        let promptTokensDetails = (usageDict["prompt_tokens_details"] as? [String: Any]) ?? [:]
        let promptTokens = usageDict["prompt_tokens"] as? Int ?? 0
        let cachedTokens = promptTokensDetails["cached_tokens"] as? Int ?? 0
        // `docs/design/16-llm-usage-stats.md` section 2: OpenAI's `prompt_tokens` *includes*
        // `cached_tokens`, unlike Anthropic's `input_tokens`, which counts only the uncached
        // portion. Subtracting here normalizes `LLMUsage.inputTokens` to the Anthropic meaning
        // everywhere downstream (`UsageRecordingLLM`/`LLMUsageAggregator`/`LLMPricing` all assume
        // "input" == "uncached input"). `max(0, ...)` guards against a hypothetical
        // `cached_tokens > prompt_tokens` response never producing a negative token count.
        let usage = LLMUsage(
            inputTokens: max(0, promptTokens - cachedTokens),
            outputTokens: usageDict["completion_tokens"] as? Int ?? 0,
            cacheReadInputTokens: cachedTokens,
            cacheCreationInputTokens: 0,
            totalCostUSD: 0
        )

        // `docs/design/16-llm-usage-stats.md` section 2: the response body's own `model` field is the
        // most authoritative record of which model actually answered -- see
        // `resolveRespondedModel`'s doc comment for why the request body's `model` can't be trusted for
        // an Azure legacy deployment URL.
        let rawResponseModel = (json["model"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let respondedModel = resolveRespondedModel(rawResponseModel: rawResponseModel, config: config, requestModel: requestModel)

        return LLMBackendResponse(structuredJSON: contentData, usage: usage, respondedModel: respondedModel)
    }

    private static func truncatedBody(_ data: Data) -> String {
        String(data: data.prefix(errorBodyByteLimit), encoding: .utf8) ?? ""
    }
}

// MARK: - Duration + TimeInterval

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
