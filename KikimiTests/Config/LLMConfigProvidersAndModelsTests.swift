import Foundation
import Testing
import Yams

@testable import Kikimi

/// Layer 1 (unit) coverage for `LLMConfig`'s §2.1 `providers`/`models`/`default` schema and its §4
/// legacy migration (`docs/design/44-llm-model-config.md`). `ModelResolver`'s own rules are covered
/// separately by `ModelResolverTests`; this file is about `LLMConfig.init(from:)`/`encode(to:)` only.
///
/// Every decode test feeds `YAMLDecoder().decode(LLMConfig.self, from:)` a snippet shaped like
/// `llm:`'s *contents* directly (not nested under an `llm:` key) -- `LLMConfig` is `Codable` on its
/// own, so this avoids going through a whole `config.yaml`/`AppConfig` round trip for tests that only
/// care about this one section. The full-file integration (`llm:` nested under `config.yaml`,
/// migration reachable through `AppConfig`) is covered by the last `MARK` section below plus the
/// existing `AppConfigTests` suite (`missingLLMKeyFallsBackToDefault`,
/// `existingConfigWithoutLLMSectionStillDecodes`, `decodesFullLLMSampleYAML`, all unaffected by this
/// module -- confirmed by that suite still passing in full).
@Suite("LLMConfig providers/models/default")
struct LLMConfigProvidersAndModelsTests {
    private func decode(_ yaml: String) throws -> LLMConfig {
        try YAMLDecoder().decode(LLMConfig.self, from: yaml)
    }

    // MARK: - New format (§2.1)

    @Test("decodes design §2.1's full providers/models/default sample")
    func decodesFullNewFormatSample() throws {
        let yaml = """
        providers:
          claude:
            kind: claude-cli
            cli_path: null
          azure:
            kind: openai
            base_url: https://res.openai.azure.com/openai/deployments/gpt-5.4-mini
            api_key_env: ""
            api_version: "2024-10-21"
            model: gpt-5.4-mini
            auth_header: ""
            reasoning_effort: none
        models:
          auto: azure/gpt-5.4-mini
          premium:
            provider: claude
            model: claude-sonnet-5
            effort: high
            timeout_seconds: 300
        default: auto
        """
        let config = try decode(yaml)

        #expect(config.providers["claude"] == .claudeCLI(ClaudeBackendConfig(cliPath: nil)))
        #expect(config.providers["azure"] == .openai(OpenAIBackendConfig(
            baseURL: "https://res.openai.azure.com/openai/deployments/gpt-5.4-mini",
            apiKey: "", apiKeyEnv: "", apiVersion: "2024-10-21", model: "gpt-5.4-mini", authHeader: "", reasoningEffort: "none"
        )))
        #expect(config.models["auto"] == ModelAliasConfig(provider: "azure", model: "gpt-5.4-mini"))
        #expect(config.models["premium"] == ModelAliasConfig(provider: "claude", model: "claude-sonnet-5", effort: "high", timeoutSeconds: 300))
        #expect(config.defaultAlias == "auto")
        #expect(config.defaultProviderName == nil)
        #expect(!config.isLegacySentinelDefault)
    }

    @Test("models decodes both the short string form and the structured object form side by side")
    func decodesModelsDualFormat() throws {
        let yaml = """
        providers:
          claude:
            kind: claude-cli
        models:
          auto: claude/claude-haiku-4-5-20251001
          bare-form: claude-haiku-4-5-20251001
          premium:
            provider: claude
            model: claude-sonnet-5
            effort: high
            timeout_seconds: 120
        default: auto
        """
        let config = try decode(yaml)

        #expect(config.models["auto"] == ModelAliasConfig(provider: "claude", model: "claude-haiku-4-5-20251001"))
        #expect(config.models["bare-form"] == ModelAliasConfig(provider: nil, model: "claude-haiku-4-5-20251001"))
        #expect(config.models["premium"] == ModelAliasConfig(provider: "claude", model: "claude-sonnet-5", effort: "high", timeoutSeconds: 120))
    }

    @Test("a provider/model string form splits at the first slash, keeping the rest as the model name")
    func decodesModelShortFormWithExtraSlash() throws {
        let yaml = """
        providers:
          azure:
            kind: openai
        models:
          auto: azure/org/deployment-name
        """
        let config = try decode(yaml)
        #expect(config.models["auto"] == ModelAliasConfig(provider: "azure", model: "org/deployment-name"))
    }

    @Test("an unknown provider kind is excluded from the registry, but other valid entries survive")
    func excludesUnknownProviderKind() throws {
        let yaml = """
        providers:
          claude:
            kind: claude-cli
          weird:
            kind: bedrock
        """
        let config = try decode(yaml)
        #expect(config.providers.keys.sorted() == ["claude"])
    }

    @Test("a provider name violating [A-Za-z0-9_-]+ is excluded from the registry, but other valid entries survive")
    func excludesInvalidProviderName() throws {
        let yaml = """
        providers:
          claude:
            kind: claude-cli
          "my/prov":
            kind: claude-cli
        """
        let config = try decode(yaml)
        #expect(config.providers.keys.sorted() == ["claude"])
    }

    @Test("a provider name using underscores/hyphens is accepted")
    func acceptsUnderscoreAndHyphenProviderNames() throws {
        let yaml = """
        providers:
          my-provider_1:
            kind: claude-cli
        """
        let config = try decode(yaml)
        #expect(config.providers.keys.sorted() == ["my-provider_1"])
    }

    @Test("an alias and a provider sharing the same name both decode without throwing")
    func aliasProviderNameCollisionStillDecodes() throws {
        let yaml = """
        providers:
          claude:
            kind: claude-cli
        models:
          claude:
            provider: claude
            model: claude-sonnet-5
        default: claude
        """
        let config = try decode(yaml)
        #expect(config.providers["claude"] == .claudeCLI(.default))
        #expect(config.models["claude"] == ModelAliasConfig(provider: "claude", model: "claude-sonnet-5"))
    }

    @Test("a provider entry missing kind is excluded from the registry, but other valid entries survive")
    func excludesProviderMissingKind() throws {
        let yaml = """
        providers:
          claude:
            kind: claude-cli
          incomplete:
            cli_path: /opt/homebrew/bin/claude
        """
        let config = try decode(yaml)
        #expect(config.providers.keys.sorted() == ["claude"])
    }

    @Test("a structurally malformed providers: value falls back to an empty registry instead of failing the whole decode")
    func malformedProvidersMapFallsBackToEmptyRegistry() throws {
        let yaml = """
        providers: not-a-map
        models:
          auto: claude/claude-haiku-4-5-20251001
        default: auto
        """
        let config = try decode(yaml)
        #expect(config.providers.isEmpty)
        // Sibling `models`/`default` keys still decode normally -- only `providers` is affected.
        #expect(config.models == ["auto": ModelAliasConfig(provider: "claude", model: "claude-haiku-4-5-20251001")])
        #expect(config.defaultAlias == "auto")
    }

    @Test("a structurally malformed models: value falls back to an empty registry instead of failing the whole decode")
    func malformedModelsMapFallsBackToEmptyRegistry() throws {
        let yaml = """
        providers:
          claude:
            kind: claude-cli
        models: not-a-map
        default: auto
        """
        let config = try decode(yaml)
        #expect(config.models.isEmpty)
        // Sibling `providers`/`default` keys still decode normally -- only `models` is affected.
        #expect(config.providers == ["claude": .claudeCLI(.default)])
        #expect(config.defaultAlias == "auto")
    }

    @Test("an unknown llm.provider value falls back to claude-cli, and the legacy migration follows that fallback")
    func unknownLegacyProviderFallsBackToClaudeCLI() throws {
        let yaml = """
        provider: bedrock
        claude:
          cli_path: /opt/homebrew/bin/claude
        """
        let config = try decode(yaml)

        #expect(config.provider == .claudeCLI)
        #expect(config.providers == ["claude": .claudeCLI(ClaudeBackendConfig(cliPath: "/opt/homebrew/bin/claude"))])
        #expect(config.defaultProviderName == "claude")
        #expect(config.isLegacySentinelDefault)
    }

    // MARK: - §4 migration

    @Test("legacy provider: claude-cli migrates into a single \"claude\" provider entry, with defaultProviderName as the sentinel")
    func migratesLegacyClaudeCLIProvider() throws {
        let yaml = """
        provider: claude-cli
        claude:
          cli_path: /opt/homebrew/bin/claude
        """
        let config = try decode(yaml)

        #expect(config.providers == ["claude": .claudeCLI(ClaudeBackendConfig(cliPath: "/opt/homebrew/bin/claude"))])
        #expect(config.models.isEmpty)
        #expect(config.defaultAlias.isEmpty)
        #expect(config.defaultProviderName == "claude")
        #expect(config.isLegacySentinelDefault)
    }

    @Test("legacy provider: openai migrates into a single \"openai\" provider entry, downgrading reasoning_effort to the provider level")
    func migratesLegacyOpenAIProviderDowngradingReasoningEffort() throws {
        let yaml = """
        provider: openai
        openai:
          base_url: https://api.openai.com/v1
          api_key_env: OPENAI_API_KEY
          model: gpt-4o-mini
          reasoning_effort: medium
        """
        let config = try decode(yaml)

        #expect(config.providers == [
            "openai": .openai(OpenAIBackendConfig(
                baseURL: "https://api.openai.com/v1", apiKey: "", apiKeyEnv: "OPENAI_API_KEY",
                apiVersion: "", model: "gpt-4o-mini", authHeader: "", reasoningEffort: "medium"
            ))
        ])
        #expect(config.defaultProviderName == "openai")
        #expect(config.isLegacySentinelDefault)
    }

    @Test("a fully-absent llm: section (via KikimiConfigData) migrates the same as an explicit provider: claude-cli")
    func absentSectionMatchesExplicitClaudeCLIDefault() throws {
        let config = try YAMLDecoder().decode(KikimiConfigData.self, from: "{}")
        #expect(config.llm == .default)
        #expect(config.llm.providers == ["claude": .claudeCLI(.default)])
        #expect(config.llm.defaultProviderName == "claude")
    }

    @Test("new format (llm.providers present) takes priority over legacy keys present alongside it, with a warning (not asserted here)")
    func newFormatWinsOverMixedLegacyKeys() throws {
        let yaml = """
        provider: openai
        openai:
          base_url: https://old.example.com/v1
        providers:
          claude:
            kind: claude-cli
        models:
          auto: claude/claude-haiku-4-5-20251001
        default: auto
        """
        let config = try decode(yaml)

        // New-format fields come only from `providers`/`models`/`default`.
        #expect(config.providers == ["claude": .claudeCLI(.default)])
        #expect(config.models == ["auto": ModelAliasConfig(provider: "claude", model: "claude-haiku-4-5-20251001")])
        #expect(config.defaultAlias == "auto")
        #expect(config.defaultProviderName == nil)
        #expect(!config.isLegacySentinelDefault)

        // The legacy fields still decode normally for old consumers (`LLMClient`, `ModelSettingsTab`,
        // ...) -- unaffected by which branch populated the new fields above.
        #expect(config.provider == .openai)
        #expect(config.openai.baseURL == "https://old.example.com/v1")
    }

    // MARK: - Round-trip / no write-back (§4)

    @Test("encoding a legacy-migrated config omits providers/models/default entirely (§4's no write-back)")
    func legacyMigratedConfigOmitsNewKeysOnEncode() throws {
        let config = try decode("""
        provider: claude-cli
        claude:
          cli_path: /opt/homebrew/bin/claude
        """)
        #expect(config.isLegacySentinelDefault)

        let encoded = try YAMLEncoder().encode(config)
        let root = try Yams.load(yaml: encoded) as? [String: Any]
        #expect(root?["providers"] == nil)
        #expect(root?["models"] == nil)
        #expect(root?["default"] == nil)
        // The legacy keys are still written (existing consumers keep reading them).
        #expect(root?["provider"] != nil)
        #expect(root?["claude"] != nil)
    }

    @Test("encoding a genuine new-format config round-trips providers/models/default")
    func newFormatConfigRoundTrips() throws {
        let original = try decode("""
        providers:
          claude:
            kind: claude-cli
        models:
          auto: claude/claude-haiku-4-5-20251001
        default: auto
        """)
        #expect(!original.isLegacySentinelDefault)

        let encoded = try YAMLEncoder().encode(original)
        let reloaded = try YAMLDecoder().decode(LLMConfig.self, from: encoded)
        #expect(reloaded == original)
    }

    @Test("encoding a genuine new-format config omits the legacy provider/claude/openai keys entirely (§9)")
    func newFormatConfigOmitsLegacyKeysOnEncode() throws {
        let original = try decode("""
        providers:
          claude:
            kind: claude-cli
          azure:
            kind: openai
            base_url: https://res.openai.azure.com/openai/deployments/gpt-5.4-mini
        models:
          auto: azure/gpt-5.4-mini
        default: auto
        """)
        #expect(!original.isLegacySentinelDefault)

        let encoded = try YAMLEncoder().encode(original)
        let root = try Yams.load(yaml: encoded) as? [String: Any]
        #expect(root?["provider"] == nil)
        #expect(root?["claude"] == nil)
        #expect(root?["openai"] == nil)
        // The new-format keys are still written.
        #expect(root?["providers"] != nil)
        #expect(root?["models"] != nil)
        #expect(root?["default"] != nil)
    }

    @Test("a config with no providers/models/default content at all (e.g. a bare memberwise construction) still round-trips through both shapes")
    func neitherShapeContentStillWritesLegacyKeys() throws {
        let config = LLMConfig(
            provider: .openai,
            claude: ClaudeBackendConfig(cliPath: "/usr/local/bin/claude"),
            openai: OpenAIBackendConfig(
                baseURL: "https://api.openai.com/v1", apiKey: "", apiKeyEnv: "", apiVersion: "",
                model: "gpt-4o-mini", authHeader: ""
            )
        )
        #expect(!config.isLegacySentinelDefault)
        #expect(config.providers.isEmpty)

        let encoded = try YAMLEncoder().encode(config)
        let root = try Yams.load(yaml: encoded) as? [String: Any]
        #expect(root?["provider"] != nil)
        #expect(root?["claude"] != nil)
        #expect(root?["openai"] != nil)
    }
}
