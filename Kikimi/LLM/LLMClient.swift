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
/// stub-mode branch (section 5), the provider registry (`docs/design/44-llm-model-config.md` §5.2),
/// and the one shared `structuredJSON` → `T` decode (`.convertFromSnakeCase`, section 6.2's
/// key-strategy note) that every backend's output goes through.
///
/// Since 44 章: no longer a single `backend`. `LLMRequest.provider` (`llm.providers` key, or `nil` for
/// the default provider) selects which `LLMBackend` handles a call, via a lazily-constructed,
/// per-provider cache (§5.2's "遅延構築").
actor LLMClient: LLMCompleting {
    static let shared = LLMClient(config: AppConfig.shared.data.llm)

    private let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "LLMClient")

    /// Startup snapshot of `llm.providers` (§5.2's "起動時スナップショット"). Provider *connection*
    /// setting changes (a new/edited entry in `llm.providers`) only take effect on the next app
    /// launch (14 章 §7's carried-forward scope-out) -- `llm.models`/`llm.default`/機能別フィールドの
    /// live-config changes are `ModelResolver`'s concern instead, resolved fresh per call by callers.
    private let providerConfigs: [String: LLMProviderConfig]
    private let credentialStore: CredentialStoring
    private let environment: [String: String]
    /// Per-provider backend cache, built lazily on first use (§5.2: "使われないプロバイダの backend を
    /// 作らないため" -- in particular so an unused `openai` provider's credential is never read, since
    /// `OpenAIChatBackend.init` itself resolves eagerly-on-first-`complete(_:)` but constructing the
    /// backend at all is still a choice this cache avoids making unless something actually dispatches
    /// to that provider).
    private var backends: [String: LLMBackend]
    private let stubProvider: LLMStubProvider

    /// The provider a `nil` `LLMRequest.provider` dispatches to (§5.2: "`request.provider`（nil は
    /// default プロバイダ）で dispatch"). Computed once at construction, mirroring what
    /// `ModelResolver.resolve(candidates: [], config:, availableProviders:)` would settle on for a
    /// caller with no candidates of its own -- every call site that predates `ModelResolver`
    /// (`Factories`/`SummaryUpdater`/`WatcherRunner`/`DictationRefiner` haven't been switched over
    /// yet; that is a later module's scope) never sets `provider` at all, so this is what keeps them
    /// behaving exactly as before this registry existed.
    private let defaultProviderName: String

    /// `providerConfigs` のキー + builtin 暗黙 `claude`（§5.2, excluding providers a decode-time
    /// validation failure already dropped -- see `LLMConfig.decodeProviders(from:)`). `ModelResolver`
    /// validates a `ModelRef`'s provider against exactly this set, never against live `AppConfig`'s
    /// `llm.providers` (§3.2's "非対称の吸収": a provider added to `config.yaml` after this process
    /// started has no live backend yet, so it must resolve the same way an unconfigured provider
    /// does -- warning + fallthrough, never a hard failure).
    nonisolated let availableProviders: Set<String>

    /// Production entry point: builds the registry from `llm.providers` (`docs/design/44-llm-model-config.md`
    /// §2.1), lazily constructing each provider's `LLMBackend` on first use.
    init(
        config: LLMConfig,
        credentialStore: CredentialStoring = DefaultCredentialStore.shared,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.providerConfigs = config.providers
        self.credentialStore = credentialStore
        self.environment = environment
        self.backends = [:]
        let available = Set(config.providers.keys).union([ModelResolver.builtinProviderName])
        self.availableProviders = available
        self.defaultProviderName = Self.resolveDefaultProviderName(config: config, availableProviders: available)
        self.stubProvider = LLMStubProvider(environment: environment)
    }

    /// Back-compat / single-backend test-and-DI seam (§5.2: "`init(backend:)`（テスト・DI 用）は
    /// 「default プロバイダとして 1 件登録」に読み替えて維持"). Every existing call site and test that
    /// builds an `LLMClient` from one hand-written `LLMBackend` keeps working unchanged: the backend
    /// is registered under the builtin provider name and used as `defaultProviderName`, so a request
    /// that never sets `.provider` (every one of them, before 44 章) dispatches to it exactly as
    /// before this registry existed.
    init(
        backend: LLMBackend,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.init(
            backends: [ModelResolver.builtinProviderName: backend],
            defaultProviderName: ModelResolver.builtinProviderName,
            environment: environment
        )
    }

    /// Registry-dispatch test seam (§5.2/§11's "レジストリ dispatch（`init(backends:)` で provider 別
    /// backend に届く）"): pre-built backends, keyed by provider name, with no lazy-construction
    /// machinery involved at all (`providerConfigs` is empty, so `backend(for:)` never reaches
    /// `Self.makeBackend` for these -- it only ever returns what's already here, falls back to an
    /// implicit `ClaudeCLIBackend()` for the reserved builtin name if that name wasn't itself
    /// provided, or throws `.unknownProvider`).
    init(
        backends: [String: LLMBackend],
        defaultProviderName: String = ModelResolver.builtinProviderName,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.providerConfigs = [:]
        self.credentialStore = InMemoryCredentialStore()
        self.environment = environment
        self.backends = backends
        self.availableProviders = Set(backends.keys).union([ModelResolver.builtinProviderName])
        self.defaultProviderName = defaultProviderName
        self.stubProvider = LLMStubProvider(environment: environment)
    }

    // MARK: - Backend factory (`docs/design/44-llm-model-config.md` §5.2/§5.3)

    /// Builds one provider's `LLMBackend` from its `LLMProviderConfig` entry. `static` and `name`-
    /// parameterized (rather than reading `providerConfigs` itself) so it stays directly unit-testable
    /// per provider, mirroring the pre-registry `makeBackend(from:)` (`docs/design/14-llm-provider.md`
    /// section 2/3) this replaces.
    ///
    /// `credentialStore` is a seam for tests: `OpenAIChatBackend.init` resolves the API key eagerly on
    /// first `complete(_:)` (never here), so calling this with the production default only reads the
    /// user's real credential store once something actually dispatches to this provider
    /// (`docs/design/35-secure-enclave-credentials.md` §4).
    static func makeBackend(
        name: String,
        config: LLMProviderConfig,
        credentialStore: CredentialStoring = DefaultCredentialStore.shared,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> LLMBackend {
        switch config {
        case .claudeCLI(let claudeConfig):
            return ClaudeCLIBackend(runner: ClaudeCLIProcessRunner(claudePathOverride: claudeConfig.cliPath))
        case .openai(let openAIConfig):
            return OpenAIChatBackend(providerName: name, config: openAIConfig, environment: environment, credentialStore: credentialStore)
        }
    }

    /// §5.2's default-provider computation: the legacy migration sentinel
    /// (`LLMConfig.defaultProviderName`) wins outright when present and still available (a legacy
    /// config always names one real provider this way, and that provider *is* what every pre-44-章
    /// call site expects a nil-provider request to reach) -- otherwise this falls through to
    /// `ModelResolver.resolve(candidates: [], ...)`'s own `llm.default` → builtin fallback (§3.2 steps
    /// 4/5), the same resolution any caller with no candidates of its own would get.
    private static func resolveDefaultProviderName(config: LLMConfig, availableProviders: Set<String>) -> String {
        if let sentinel = config.defaultProviderName, availableProviders.contains(sentinel) {
            return sentinel
        }
        return ModelResolver.resolve(candidates: [], config: config, availableProviders: availableProviders).provider
    }

    // MARK: - Registry dispatch (§5.2)

    /// Resolves `providerName` (or `defaultProviderName` when `nil`) to a `LLMBackend`, constructing
    /// and caching it on first use. The reserved builtin provider name
    /// (`ModelResolver.builtinProviderName`) always succeeds, even when `providerConfigs` has no entry
    /// for it (§3.2 step 5's "`llm.providers` が空でも成立する" builtin fallback, mirrored here so the
    /// registry and `ModelResolver` never disagree about what `"claude"` means). Every other name
    /// absent from both the cache and `providerConfigs` throws `.unknownProvider` -- reachable only as
    /// a DI/wiring-bug last line of defense, since `ModelResolver` validates provider existence against
    /// `availableProviders` before ever producing a request that reaches here (§5.2).
    private func backend(for providerName: String?) throws -> LLMBackend {
        let name = providerName ?? defaultProviderName
        if let cached = backends[name] {
            return cached
        }
        guard let providerConfig = providerConfigs[name] else {
            if name == ModelResolver.builtinProviderName {
                let builtin = ClaudeCLIBackend()
                backends[name] = builtin
                return builtin
            }
            logger.error("no LLM backend registered for provider \"\(name, privacy: .public)\"")
            throw LLMClientError.unknownProvider(name: name)
        }
        let built = Self.makeBackend(name: name, config: providerConfig, credentialStore: credentialStore, environment: environment)
        backends[name] = built
        return built
    }

    // MARK: - LLMCompleting

    func complete<T: Decodable & Sendable>(_ request: LLMRequest) async throws -> LLMResult<T> {
        if stubProvider.isEnabled {
            // Section 5: no backend is ever touched in stub mode, by construction -- the registry
            // isn't consulted on this branch at all, same as before it existed.
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
    /// resolution as `complete(_:)`, just skipped past the `T` decode -- and never touches the
    /// registry, same as `complete(_:)`. Production mode dispatches to `request.provider`'s backend and
    /// returns its `structuredJSON`/`usage` completely undecoded: no `.convertFromSnakeCase`, no
    /// `Decodable` type, since the caller's schema is only known at runtime (`WatcherRunner`).
    func completeRaw(_ request: LLMRequest) async throws -> LLMResult<Data> {
        if stubProvider.isEnabled {
            do {
                return try stubProvider.stubRawResult(for: request)
            } catch let error as LLMClientError {
                logger.warning("stub LLM raw response unavailable: \(String(describing: error), privacy: .public)")
                throw error
            }
        }
        let target = try backend(for: request.provider)
        let response = try await target.complete(request)
        return LLMResult(value: response.structuredJSON, usage: response.usage, respondedModel: response.respondedModel)
    }

    // MARK: - Health check (section 3 "起動時ヘルスチェック")

    /// Back-compat overload (`docs/design/44-llm-model-config.md` §5.2: "後方互換の既定引数で現行呼び出
    /// しを壊さない"): probes `defaultProviderName` with `model`, so callers written before
    /// `ResolvedModel` existed keep compiling and behaving unchanged.
    ///
    /// - Parameter model: Model id to probe with. Defaults to kikimi.md 12 章's config default so
    ///   callers that haven't resolved `AppConfig` yet still get a meaningful check.
    func healthCheck(model: String = "claude-haiku-4-5-20251001") async -> LLMHealthCheckResult {
        await healthCheck(resolved: ResolvedModel(provider: defaultProviderName, model: model))
    }

    /// Lightweight backend-availability probe for a startup warning UI. Issues one real minimal
    /// structured-output call through `resolved.provider`'s backend, so e.g. a CLI version that
    /// rejects one of the newer flags (`--json-schema` etc.), or an unreachable/misconfigured
    /// OpenAI-compatible endpoint, is caught before a consumer component relies on it. Always reports
    /// `.available` in stub mode without touching any backend. UI wiring remains out of scope for this
    /// module (§5.2's "配線は本設計でも引き続きスコープ外").
    func healthCheck(resolved: ResolvedModel) async -> LLMHealthCheckResult {
        if stubProvider.isEnabled {
            return .available
        }
        let probeRequest = LLMRequest(
            system: "You are a health check probe. Reply with the requested structured output only.",
            user: "ping",
            schema: Self.healthCheckSchema,
            model: resolved.model,
            timeout: Self.healthCheckTimeout,
            provider: resolved.provider,
            params: resolved.params
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
        let target = try backend(for: request.provider)
        let response = try await target.complete(request)

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
