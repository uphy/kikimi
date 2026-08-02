import Foundation
import OSLog

// MARK: - LLMProviderKind

/// `llm.provider` (`docs/design/14-llm-provider.md` section 3). Selects which `LLMBackend`
/// `LLMClient.shared` is built from (`LLMClient.makeBackend(from:)`).
enum LLMProviderKind: String, Codable, Equatable, Sendable {
    case claudeCLI = "claude-cli"
    case openai
}

// MARK: - ClaudeBackendConfig

/// `llm.claude:` section (`docs/design/14-llm-provider.md` section 3). Wires
/// `ClaudeCLIProcessRunner(claudePathOverride:)`'s already-existing parameter
/// (`Kikimi/LLM/LLMProcessRunner.swift`'s "12 章 §3.1 step 1 の実装化" note).
struct ClaudeBackendConfig: Codable, Equatable, Sendable {
    /// Explicit `claude` executable path. `nil`/absent falls through to `ClaudeCLIProcessRunner`'s
    /// own `which`/known-candidate-path resolution (`docs/design/12-llm-client.md` section 3.1).
    var cliPath: String?

    enum CodingKeys: String, CodingKey {
        case cliPath = "cli_path"
    }

    static let `default` = ClaudeBackendConfig(cliPath: nil)

    init(cliPath: String?) {
        self.cliPath = cliPath
    }

    /// Custom decoder mirroring `DiarizationConfig.init(from:)`: a partial (or absent) `llm.claude:`
    /// section fills the missing field from `.default` instead of failing the whole `config.yaml`
    /// decode.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cliPath = try container.decodeIfPresent(String.self, forKey: .cliPath) ?? Self.default.cliPath
    }
}

// MARK: - OpenAIBackendConfig

/// `llm.openai:` section (`docs/design/14-llm-provider.md` section 3). Drives `OpenAIChatBackend`'s
/// request assembly (URL, auth header, model override, API key resolution).
struct OpenAIBackendConfig: Codable, Equatable, Sendable {
    /// Required for the `openai` provider to function; empty is a valid (if unusable) default so a
    /// partial section still decodes. Examples (section 3): OpenAI `https://api.openai.com/v1`,
    /// Azure v1 `https://<res>.openai.azure.com/openai/v1`, Azure legacy
    /// `https://<res>.openai.azure.com/openai/deployments/<dep>`.
    var baseURL: String
    /// Direct API key. Config-file-plaintext is accepted (kikimi.md 12 章: local personal app).
    var apiKey: String
    /// Environment variable name to read the API key from when `apiKey` is empty (section 3's "API
    /// キー解決順").
    var apiKeyEnv: String
    /// Non-empty appends `?api-version=<value>` (Azure legacy form, section 4.1).
    var apiVersion: String
    /// Non-empty overrides every call's `model` (Azure deployment-name workflow, section 3's "モデル解決").
    var model: String
    /// `"bearer"` | `"api-key"` | `""` (derived from `apiVersion`'s presence when empty, section 3).
    var authHeader: String
    /// Non-empty sends `reasoning_effort` on every call (gpt-5-series reasoning models' `"none"`/
    /// `"minimal"`/.../`"xhigh"`); empty omits the field entirely, since non-reasoning models reject it.
    var reasoningEffort: String

    enum CodingKeys: String, CodingKey {
        case baseURL = "base_url"
        case apiKey = "api_key"
        case apiKeyEnv = "api_key_env"
        case apiVersion = "api_version"
        case model
        case authHeader = "auth_header"
        case reasoningEffort = "reasoning_effort"
    }

    static let `default` = OpenAIBackendConfig(baseURL: "", apiKey: "", apiKeyEnv: "", apiVersion: "", model: "", authHeader: "", reasoningEffort: "")

    init(baseURL: String, apiKey: String, apiKeyEnv: String, apiVersion: String, model: String, authHeader: String, reasoningEffort: String = "") {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.apiKeyEnv = apiKeyEnv
        self.apiVersion = apiVersion
        self.model = model
        self.authHeader = authHeader
        self.reasoningEffort = reasoningEffort
    }

    /// Custom decoder mirroring `DiarizationConfig.init(from:)`: a partial (or absent) `llm.openai:`
    /// section fills every missing field from `.default` instead of failing the whole `config.yaml`
    /// decode.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? Self.default.baseURL
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? Self.default.apiKey
        apiKeyEnv = try container.decodeIfPresent(String.self, forKey: .apiKeyEnv) ?? Self.default.apiKeyEnv
        apiVersion = try container.decodeIfPresent(String.self, forKey: .apiVersion) ?? Self.default.apiVersion
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? Self.default.model
        authHeader = try container.decodeIfPresent(String.self, forKey: .authHeader) ?? Self.default.authHeader
        reasoningEffort = try container.decodeIfPresent(String.self, forKey: .reasoningEffort) ?? Self.default.reasoningEffort
    }
}

// MARK: - LLMProviderConfig

/// `llm.providers.<name>:` entry (`docs/design/44-llm-model-config.md` §2.1). A tagged union
/// discriminated by `kind` (`claude-cli` | `openai`); the rest of the entry's keys are the same flat
/// fields `ClaudeBackendConfig`/`OpenAIBackendConfig` already model (not nested under a `claude:`/
/// `openai:` sub-key the way the legacy `llm.claude`/`llm.openai` sections are).
enum LLMProviderConfig: Equatable, Sendable {
    case claudeCLI(ClaudeBackendConfig)
    case openai(OpenAIBackendConfig)

    /// The `kind:` value this entry would (re-)encode as.
    var kind: LLMProviderKind {
        switch self {
        case .claudeCLI: return .claudeCLI
        case .openai: return .openai
        }
    }
}

extension LLMProviderConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
    }

    /// Not used by `LLMConfig`'s own decode path (`LLMConfig.decodeProviders(from:)` decodes each
    /// entry leniently, one at a time, so a single malformed/unknown-`kind` entry only excludes that
    /// entry -- §2.1's "未知の kind を持つプロバイダは warning を出してレジストリから除外する" --
    /// rather than failing the whole `providers:` map). Kept for direct unit-test construction
    /// (`YAMLDecoder().decode(LLMProviderConfig.self, from:)`) and round-trip symmetry with `encode`.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kindRaw = try container.decode(String.self, forKey: .kind)
        switch kindRaw {
        case LLMProviderKind.claudeCLI.rawValue:
            self = .claudeCLI(try ClaudeBackendConfig(from: decoder))
        case LLMProviderKind.openai.rawValue:
            self = .openai(try OpenAIBackendConfig(from: decoder))
        default:
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown provider kind \"\(kindRaw)\"")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind.rawValue, forKey: .kind)
        switch self {
        case .claudeCLI(let config):
            try config.encode(to: encoder)
        case .openai(let config):
            try config.encode(to: encoder)
        }
    }
}

/// Every string field of `ClaudeBackendConfig`/`OpenAIBackendConfig` merged flat, all-optional, used
/// only to leniently pre-decode one `llm.providers.<name>:` entry (`LLMConfig.decodeProviders(from:)`)
/// before its `kind`/name are validated. Kept private to this file -- nothing outside `LLMConfig`'s
/// own decode needs it.
private struct LLMProviderRawEntry: Decodable {
    enum CodingKeys: String, CodingKey {
        case kind
        case cliPath = "cli_path"
        case baseURL = "base_url"
        case apiKey = "api_key"
        case apiKeyEnv = "api_key_env"
        case apiVersion = "api_version"
        case model
        case authHeader = "auth_header"
        case reasoningEffort = "reasoning_effort"
    }

    var kind: String?
    var cliPath: String?
    var baseURL: String?
    var apiKey: String?
    var apiKeyEnv: String?
    var apiVersion: String?
    var model: String?
    var authHeader: String?
    var reasoningEffort: String?
}

// MARK: - ModelAliasConfig

/// `llm.models.<name>:` entry (`docs/design/44-llm-model-config.md` §2.1/§3.1). Decodes from either
/// the short string form (`"provider/model"` or a bare model name) or the structured object form
/// (`{provider, model, effort, timeout_seconds}`) -- the string form is parsed eagerly here per §3.1
/// rules 2/3 (a syntactic split only; provider *existence* is validated later by `ModelResolver`
/// against the live `availableProviders` snapshot, not at decode time).
struct ModelAliasConfig: Equatable, Sendable {
    /// `nil` when this definition came from a bare-model-name string (no `/`) -- `ModelResolver`
    /// then borrows `llm.default`'s resolved provider only, never its params (§3.1 rule 3; "alias
    /// 値は再帰的に alias を参照できない... 1 段展開のみ").
    var provider: String?
    var model: String
    var effort: String?
    var timeoutSeconds: Int?

    init(provider: String?, model: String, effort: String? = nil, timeoutSeconds: Int? = nil) {
        self.provider = provider
        self.model = model
        self.effort = effort
        self.timeoutSeconds = timeoutSeconds
    }

    /// §2.1's short string form, split per §3.1 rules 2 (`"provider/model"`, split at the *first*
    /// `/` so the model half may itself contain `/`) / 3 (no `/` at all -- a bare model name).
    static func parsingShortForm(_ shortForm: String) -> ModelAliasConfig {
        guard let slashIndex = shortForm.firstIndex(of: "/") else {
            return ModelAliasConfig(provider: nil, model: shortForm)
        }
        let providerPart = String(shortForm[shortForm.startIndex..<slashIndex])
        let modelPart = String(shortForm[shortForm.index(after: slashIndex)...])
        return ModelAliasConfig(provider: providerPart, model: modelPart)
    }
}

extension ModelAliasConfig: Codable {
    enum CodingKeys: String, CodingKey {
        case provider
        case model
        case effort
        case timeoutSeconds = "timeout_seconds"
    }

    /// Tries the short string form first (§2.1's "decode は文字列を先に試し、失敗したらオブジェクト
    /// として decode する" -- same two-form pattern as `JSONValue`); falls back to the structured
    /// object form on any failure (mistyped, or genuinely an object node).
    init(from decoder: Decoder) throws {
        if let shortForm = try? decoder.singleValueContainer().decode(String.self) {
            self = Self.parsingShortForm(shortForm)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decodeIfPresent(String.self, forKey: .provider)
        model = try container.decode(String.self, forKey: .model)
        effort = try container.decodeIfPresent(String.self, forKey: .effort)
        timeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .timeoutSeconds)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(provider, forKey: .provider)
        try container.encode(model, forKey: .model)
        try container.encodeIfPresent(effort, forKey: .effort)
        try container.encodeIfPresent(timeoutSeconds, forKey: .timeoutSeconds)
    }
}

// MARK: - LLMConfig

/// `llm:` section of `config.yaml` (`docs/design/14-llm-provider.md` section 3,
/// `docs/design/44-llm-model-config.md` §2). Selects and configures the `LLMBackend`(s)
/// `LLMClient.shared` is built from.
///
/// Carries two generations of the same information side by side:
/// - `provider`/`claude`/`openai` (14 章's single-provider shape) -- kept exactly as before so every
///   existing consumer (`LLMClient`, `ClaudeCLIBackend`, `OpenAIChatBackend`,
///   `RefinementQueue+BatchProcessing`, `SettingsViewModel`, `ModelSettingsTab`) keeps compiling and
///   behaving unchanged. This module (`docs/design/44-llm-model-config.md` §1's "実装は3 Phase に
///   分割する") intentionally does not touch any of those call sites.
/// - `providers`/`models`/`defaultAlias` (44 章's named-provider shape) -- what `ModelResolver`
///   (`Kikimi/LLM/ModelRef.swift`) consumes. Populated either straight from a genuine `llm.providers:`
///   section, or synthesized from the legacy fields above (§4's migration) when that section is
///   absent -- see `defaultProviderName`'s doc comment for how the two migration outcomes differ.
struct LLMConfig: Codable, Equatable, Sendable {
    var provider: LLMProviderKind
    var claude: ClaudeBackendConfig
    var openai: OpenAIBackendConfig
    /// `llm.pricing` (`docs/design/16-llm-usage-stats.md` section 4): per-model USD/1M-token
    /// overrides, keyed by model id prefix. Takes priority over `LLMPricing.builtIn` when both
    /// tables have a matching prefix (`LLMPricing.resolve(model:configPricing:)`'s job, not this
    /// struct's) -- primarily for the Azure OpenAI deployment-name workflow, where the model id
    /// itself carries no pricing information at all.
    var pricing: [String: LLMModelPricing]

    /// `llm.providers` (§2.1). Keys are validated against `[A-Za-z0-9_-]+`
    /// (`LLMConfig.isValidProviderName(_:)`); entries with an invalid name or unrecognized `kind` are
    /// dropped with a warning rather than failing the whole `config.yaml` decode (§2.1/§10).
    var providers: [String: LLMProviderConfig]
    /// `llm.models` (§2.1). No reserved names ("予約名は設けない") -- every entry is an ordinary,
    /// user-defined alias; `ModelResolver` never synthesizes a definition for a name this dictionary
    /// omits.
    var models: [String: ModelAliasConfig]
    /// `llm.default` (§2.1), an alias name (e.g. `"auto"`). Empty when this config came from the
    /// legacy shape (`defaultProviderName` carries the migrated equivalent instead) or genuinely
    /// omitted the key.
    var defaultAlias: String
    /// §4's migration sentinel: non-nil iff this `LLMConfig` was populated from the legacy
    /// `llm.provider` + `llm.claude`/`llm.openai` shape (no `llm.providers:` key on disk) rather than
    /// a genuine `llm.providers:` section. Holds the single synthesized provider name (`providers`'s
    /// only key) so `ModelResolver` can supply "default's provider" for bare-model-name resolution
    /// (§3.1 rule 3) even though there is no real `llm.models` alias to look it up from -- the
    /// sentinel has no model name of its own, so it can never itself stand in for `llm.default` at
    /// resolution step 4 (§3.2; that always falls straight through to the builtin default for a
    /// legacy config). Also gates `encode(to:)`: while this is set, `providers`/`models`/`defaultAlias`
    /// are never written back to disk (§4's "config.yaml への書き戻しはしない").
    var defaultProviderName: String?

    /// Derived from `defaultProviderName` (§4's "実装上は `defaultProviderName` を decode 結果として
    /// 持てば足りる" plus the `isLegacySentinelDefault` name §4 calls for explicitly).
    var isLegacySentinelDefault: Bool { defaultProviderName != nil }

    enum CodingKeys: String, CodingKey {
        case provider
        case claude
        case openai
        case pricing
        case providers
        case models
        case defaultAlias = "default"
    }

    /// `provider: claude-cli` (back-compat default, section 3). `pricing` defaults to empty --
    /// `LLMPricing.builtIn` alone covers every Anthropic model kikimi.md 12 章 documents. The new
    /// §2.1 fields default to the same "no `llm.providers:` on disk" migration outcome
    /// `init(from:)` produces for a `provider: claude-cli` config (`defaultProviderName`'s doc
    /// comment) -- so `LLMConfig.default == LLMConfig(from: <a config.yaml missing the llm: key>)`.
    static let `default` = LLMConfig(
        provider: .claudeCLI, claude: .default, openai: .default, pricing: [:],
        providers: ["claude": .claudeCLI(.default)], models: [:], defaultAlias: "", defaultProviderName: "claude"
    )

    init(
        provider: LLMProviderKind,
        claude: ClaudeBackendConfig,
        openai: OpenAIBackendConfig,
        pricing: [String: LLMModelPricing] = [:],
        providers: [String: LLMProviderConfig] = [:],
        models: [String: ModelAliasConfig] = [:],
        defaultAlias: String = "",
        defaultProviderName: String? = nil
    ) {
        self.provider = provider
        self.claude = claude
        self.openai = openai
        self.pricing = pricing
        self.providers = providers
        self.models = models
        self.defaultAlias = defaultAlias
        self.defaultProviderName = defaultProviderName
    }

    private static let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "LLMConfig")

    /// Custom decoder mirroring `DiarizationConfig.init(from:)`: a partial (or absent) `llm:` section
    /// fills every missing field from `.default`. An unrecognized `provider` value is logged as a
    /// warning and falls back to `.claudeCLI` (section 3's "未知 provider は warning + claude-cli
    /// フォールバック") rather than failing the whole `config.yaml` decode.
    ///
    /// §4's migration and §2.1's `providers`/`models` validation happen here too, once the legacy
    /// fields above are settled.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let providerRaw = try container.decodeIfPresent(String.self, forKey: .provider) {
            if let resolved = LLMProviderKind(rawValue: providerRaw) {
                provider = resolved
            } else {
                Self.logger.warning(
                    "llm.provider=\(providerRaw, privacy: .public) is unknown; falling back to \(LLMProviderKind.claudeCLI.rawValue, privacy: .public)"
                )
                provider = .claudeCLI
            }
        } else {
            provider = Self.default.provider
        }

        claude = try container.decodeIfPresent(ClaudeBackendConfig.self, forKey: .claude) ?? .default
        openai = try container.decodeIfPresent(OpenAIBackendConfig.self, forKey: .openai) ?? .default
        pricing = try container.decodeIfPresent([String: LLMModelPricing].self, forKey: .pricing) ?? [:]

        // §4: new format is authoritative whenever `llm.providers:` is present at all (even an empty
        // map) -- "新旧混在（providers と provider が両方ある）は新形式を採り、旧キーは無視 +
        // warning". Otherwise this is either a genuinely legacy config or one that never had an
        // `llm:` section to begin with; both synthesize the same single-provider registry the old
        // `provider`/`claude`/`openai` fields above already decoded (§4's migration table).
        let hasNewProviders = container.contains(.providers)
        if hasNewProviders {
            let hasLegacyKeys = container.contains(.provider) || container.contains(.claude) || container.contains(.openai)
            if hasLegacyKeys {
                Self.logger.warning(
                    "llm.providers is present alongside legacy llm.provider/claude/openai keys; using llm.providers and ignoring the legacy keys for provider/model resolution"
                )
            }
            providers = Self.decodeProviders(from: container, logger: Self.logger)
            models = Self.decodeModels(from: container, logger: Self.logger)
            defaultAlias = try container.decodeIfPresent(String.self, forKey: .defaultAlias) ?? ""
            defaultProviderName = nil
        } else {
            let migratedName = provider == .openai ? "openai" : "claude"
            switch provider {
            case .claudeCLI:
                providers = [migratedName: .claudeCLI(claude)]
            case .openai:
                providers = [migratedName: .openai(openai)]
            }
            models = [:]
            defaultAlias = ""
            defaultProviderName = migratedName
        }

        Self.warnOnAliasProviderNameCollisions(models: models, providers: providers, logger: Self.logger)
    }

    /// §4's "config.yaml への書き戻しはしない" plus §9's "編集すると新形式で保存される": which shape(s)
    /// get written depends on how this `LLMConfig` came to be, in three cases --
    /// - **Legacy sentinel** (`defaultProviderName` set -- this config was synthesized from the
    ///   legacy `llm.provider`/`llm.claude`/`llm.openai` shape, never read from a genuine
    ///   `llm.providers:` section): only the legacy keys are written, exactly as before this module
    ///   (§4's no-write-back).
    /// - **Genuine new format** (`defaultProviderName` nil *and* at least one of
    ///   `providers`/`models`/`defaultAlias` is actually populated -- either decoded from a real
    ///   `llm.providers:` section, or edited through the new Settings "モデル" tab via
    ///   `AppConfig.updateLLM(_:)`, which clears `defaultProviderName` in the same `update {}`):
    ///   only the new §2.1 keys are written. This is what makes the Phase 1 caveat ("旧 UI で保存す
    ///   ると旧形式のまま書かれる") go away in Phase 3 -- once the user has touched anything in the
    ///   new tab, the legacy keys stop being written at all, so they cannot linger stale on disk.
    /// - **Neither** (`defaultProviderName` nil and `providers`/`models`/`defaultAlias` all empty --
    ///   e.g. a bare `LLMConfig(provider:claude:openai:)` test construction that never touched
    ///   either shape): both shapes are written, matching this type's pre-module behavior so nothing
    ///   that only reads the legacy fields after such a round trip regresses.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pricing, forKey: .pricing)

        if defaultProviderName != nil {
            try container.encode(provider, forKey: .provider)
            try container.encode(claude, forKey: .claude)
            try container.encode(openai, forKey: .openai)
            return
        }

        let hasNewFormatContent = !providers.isEmpty || !models.isEmpty || !defaultAlias.isEmpty
        if !hasNewFormatContent {
            try container.encode(provider, forKey: .provider)
            try container.encode(claude, forKey: .claude)
            try container.encode(openai, forKey: .openai)
        }
        try container.encode(providers, forKey: .providers)
        try container.encode(models, forKey: .models)
        try container.encode(defaultAlias, forKey: .defaultAlias)
    }

    /// §2.1: provider names are constrained to `[A-Za-z0-9_-]+` (same character set as
    /// `MeetingProfileIdValidation.validate(_:)`, plus underscore) because the name is embedded
    /// verbatim in a credential account string (§6, `CredentialAccount.providerAPIKey(name:)`) whose
    /// file layout collapses other punctuation to `_` -- an unconstrained name like `"my/prov"` would
    /// collide on disk with a literal `"my_prov"` and the two providers would silently share (and
    /// overwrite) one API key.
    static func isValidProviderName(_ name: String) -> Bool {
        !name.isEmpty && name.unicodeScalars.allSatisfy { scalar in
            ("a"..."z").contains(Character(scalar)) ||
                ("A"..."Z").contains(Character(scalar)) ||
                ("0"..."9").contains(Character(scalar)) ||
                scalar == "-" || scalar == "_"
        }
    }

    /// Decodes `llm.providers` leniently: a structurally malformed `providers:` map (not even a
    /// name → object mapping) falls back to an empty registry with a warning, but once that much
    /// decodes, each *entry* is validated independently -- an invalid name (`isValidProviderName`) or
    /// unrecognized `kind` excludes only that one entry (§2.1/§10), it never fails the others.
    private static func decodeProviders(
        from container: KeyedDecodingContainer<CodingKeys>,
        logger: Logger
    ) -> [String: LLMProviderConfig] {
        let raw: [String: LLMProviderRawEntry]
        do {
            raw = try container.decodeIfPresent([String: LLMProviderRawEntry].self, forKey: .providers) ?? [:]
        } catch {
            logger.warning(
                "llm.providers failed to decode (\(String(describing: error), privacy: .public)); falling back to an empty provider registry"
            )
            return [:]
        }

        var result: [String: LLMProviderConfig] = [:]
        for (name, entry) in raw {
            guard isValidProviderName(name) else {
                logger.warning(
                    "llm.providers.\(name, privacy: .public) has an invalid name (must match [A-Za-z0-9_-]+); excluding it"
                )
                continue
            }
            guard let kindRaw = entry.kind else {
                logger.warning(
                    "llm.providers.\(name, privacy: .public) is missing kind; excluding it from the provider registry"
                )
                continue
            }
            switch kindRaw {
            case LLMProviderKind.claudeCLI.rawValue:
                result[name] = .claudeCLI(ClaudeBackendConfig(cliPath: entry.cliPath))
            case LLMProviderKind.openai.rawValue:
                result[name] = .openai(OpenAIBackendConfig(
                    baseURL: entry.baseURL ?? "",
                    apiKey: entry.apiKey ?? "",
                    apiKeyEnv: entry.apiKeyEnv ?? "",
                    apiVersion: entry.apiVersion ?? "",
                    model: entry.model ?? "",
                    authHeader: entry.authHeader ?? "",
                    reasoningEffort: entry.reasoningEffort ?? ""
                ))
            default:
                logger.warning(
                    "llm.providers.\(name, privacy: .public) has unknown kind=\(kindRaw, privacy: .public); excluding it"
                )
            }
        }
        return result
    }

    /// Decodes `llm.models` leniently: a structurally malformed `models:` map falls back to an empty
    /// registry with a warning (§2.1's usual partial-decode leniency) -- `ModelAliasConfig`'s own
    /// `init(from:)` already never throws for either of its two valid forms, so per-entry recovery
    /// is not needed here the way it is for `providers`.
    private static func decodeModels(
        from container: KeyedDecodingContainer<CodingKeys>,
        logger: Logger
    ) -> [String: ModelAliasConfig] {
        do {
            return try container.decodeIfPresent([String: ModelAliasConfig].self, forKey: .models) ?? [:]
        } catch {
            logger.warning(
                "llm.models failed to decode (\(String(describing: error), privacy: .public)); falling back to an empty model registry"
            )
            return [:]
        }
    }

    /// §3.1: "alias 名とプロバイダ名が衝突している場合は alias が勝つ（decode 時に warning を出す）".
    /// `ModelResolver` already resolves this correctly by construction (alias lookup, §3.1 rule 1, is
    /// always tried before the provider/model split, rule 2) -- this only surfaces the collision to
    /// the log so a user who defines `models.claude` alongside `providers.claude` learns why
    /// `ModelRef` `"claude"` never reaches the provider directly.
    private static func warnOnAliasProviderNameCollisions(
        models: [String: ModelAliasConfig],
        providers: [String: LLMProviderConfig],
        logger: Logger
    ) {
        for name in models.keys where providers.keys.contains(name) {
            logger.warning(
                "llm.models.\(name, privacy: .public) collides with llm.providers.\(name, privacy: .public); the alias wins when resolving this ModelRef"
            )
        }
    }
}
