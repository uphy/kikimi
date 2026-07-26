import Foundation
import OSLog

// MARK: - LLMClient

/// Production implementation of `LLMCompleting` -- the single window every LLM-calling component
/// (refinement / summary / watchers) goes through (`docs/design/12-llm-client.md` section 1).
///
/// Actor-isolated so its in-flight bookkeeping stays race-free; this does **not** by itself serialize
/// concurrent `complete(_:)` calls to a single backend call (section 4's "並行度" note -- a caller
/// that needs that guarantee provides it itself, e.g. `SummaryUpdater` running one batch at a time).
///
/// Provider-specific wire handling lives in `LLMBackend` implementations
/// (`docs/design/14-llm-provider.md` section 2): `ClaudeCLIBackend` for the `claude` CLI subprocess,
/// `OpenAIChatBackend` for OpenAI-compatible HTTP chat completions. `LLMClient` itself only owns the
/// stub-mode branch (section 5) and the one shared `structuredJSON` → `T` decode
/// (`.convertFromSnakeCase`, section 6.2's key-strategy note) that every backend's output goes
/// through.
actor LLMClient: LLMCompleting {
    static let shared = LLMClient(backend: LLMClient.makeBackend(from: AppConfig.shared.data.llm))

    private let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "LLMClient")

    private let backend: LLMBackend
    private let stubProvider: LLMStubProvider

    init(
        backend: LLMBackend = ClaudeCLIBackend(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.backend = backend
        self.stubProvider = LLMStubProvider(environment: environment)
    }

    // MARK: - Backend factory (`docs/design/14-llm-provider.md` section 2 / 3)

    /// Builds the `LLMBackend` `shared` uses, per `llm.provider` (`LLMConfig`, decoded by
    /// `AppConfig`). Unknown/missing `provider` values are already resolved to `.claudeCLI` by
    /// `LLMConfig`'s own lenient decoder (section 3: "未知 provider は warning + claude-cli
    /// フォールバック"), so this switch never needs a fallback branch of its own.
    ///
    /// `credentialStore` is a seam for tests: `OpenAIChatBackend.init` resolves the API key eagerly,
    /// so calling this with the production default reads the user's real credential store
    /// (`docs/design/35-secure-enclave-credentials.md` §4).
    static func makeBackend(
        from config: LLMConfig,
        credentialStore: CredentialStoring = DefaultCredentialStore.shared
    ) -> LLMBackend {
        switch config.provider {
        case .claudeCLI:
            return ClaudeCLIBackend(runner: ClaudeCLIProcessRunner(claudePathOverride: config.claude.cliPath))
        case .openai:
            return OpenAIChatBackend(config: config.openai, credentialStore: credentialStore)
        }
    }

    // MARK: - LLMCompleting

    func complete<T: Decodable & Sendable>(_ request: LLMRequest) async throws -> LLMResult<T> {
        if stubProvider.isEnabled {
            // Section 5: no backend is ever touched in stub mode, by construction -- `backend` isn't
            // referenced on this branch at all.
            do {
                return try stubProvider.stubResult(for: request)
            } catch let error as LLMClientError {
                logger.warning("stub LLM response unavailable: \(String(describing: error), privacy: .public)")
                throw error
            }
        }
        return try await runAndDecode(request)
    }

    /// Raw-JSON counterpart of `complete(_:)` (`docs/design/05-watcher-runner.md` §5.1). Stub mode
    /// dispatches to `LLMStubProvider.stubRawResult(for:)` -- the same `stubKey`/`overrides`
    /// resolution as `complete(_:)`, just skipped past the `T` decode -- and never touches `backend`,
    /// same as `complete(_:)`. Production mode calls the backend and returns its
    /// `structuredJSON`/`usage` completely undecoded: no `.convertFromSnakeCase`, no `Decodable`
    /// type, since the caller's schema is only known at runtime (`WatcherRunner`).
    func completeRaw(_ request: LLMRequest) async throws -> LLMResult<Data> {
        if stubProvider.isEnabled {
            do {
                return try stubProvider.stubRawResult(for: request)
            } catch let error as LLMClientError {
                logger.warning("stub LLM raw response unavailable: \(String(describing: error), privacy: .public)")
                throw error
            }
        }
        let response = try await backend.complete(request)
        return LLMResult(value: response.structuredJSON, usage: response.usage, respondedModel: response.respondedModel)
    }

    // MARK: - Health check (section 3 "起動時ヘルスチェック")

    /// Lightweight backend-availability probe for a startup warning UI. Issues one real minimal
    /// structured-output call through the configured backend, so e.g. a CLI version that rejects one
    /// of the newer flags (`--json-schema` etc.), or an unreachable/misconfigured OpenAI-compatible
    /// endpoint, is caught before a consumer component relies on it. Always reports `.available` in
    /// stub mode without touching the backend.
    ///
    /// - Parameter model: Model id to probe with. Defaults to kikimi.md 12 章's config default so
    ///   callers that haven't resolved `AppConfig` yet still get a meaningful check.
    func healthCheck(model: String = "claude-haiku-4-5-20251001") async -> LLMHealthCheckResult {
        if stubProvider.isEnabled {
            return .available
        }
        let probeRequest = LLMRequest(
            system: "You are a health check probe. Reply with the requested structured output only.",
            user: "ping",
            schema: Self.healthCheckSchema,
            model: model,
            timeout: Self.healthCheckTimeout
        )
        do {
            let _: LLMResult<HealthCheckProbeResponse> = try await runAndDecode(probeRequest)
            return .available
        } catch let error as LLMClientError {
            return .unavailable(error)
        } catch {
            return .unavailable(.processFailed(exitCode: -1, stderr: "\(error)"))
        }
    }

    // MARK: - Backend invocation + shared T decode

    private func runAndDecode<T: Decodable & Sendable>(_ request: LLMRequest) async throws -> LLMResult<T> {
        let response = try await backend.complete(request)

        // The one shared `structuredJSON` → `T` decode every backend's output goes through
        // (`docs/design/12-llm-client.md` section 6.2's key-strategy note): schemas are snake_case
        // (matching what's handed to `--json-schema` / `response_format.json_schema.schema`), decoded
        // here into consumer `T`s with plain camelCase properties.
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            let value = try decoder.decode(T.self, from: response.structuredJSON)
            return LLMResult(value: value, usage: response.usage, respondedModel: response.respondedModel)
        } catch {
            let wrapped = LLMClientError.decodeFailed(underlying: String(describing: error))
            logger.error("structured_output could not be decoded into the expected type: \(String(describing: wrapped), privacy: .public)")
            throw wrapped
        }
    }

    private static let healthCheckSchema = """
    {"type":"object","properties":{"ok":{"type":"boolean"}},"required":["ok"]}
    """
    private static let healthCheckTimeout: Duration = .seconds(15)
}

// MARK: - HealthCheckProbeResponse

private struct HealthCheckProbeResponse: Decodable, Sendable, Equatable {
    var ok: Bool
}
