import Foundation
import Testing

@testable import Kikimi

/// Layer 1 (unit) coverage for `LLMProviderRename.rename(config:from:to:)`
/// (`docs/design/44-llm-model-config.md` §9's "rename は「models の参照書き換え + credential move」
/// を1つの update {} で原子的に行う", tested here as the pure rewrite half). Every test builds an
/// `LLMConfig` directly via its designated initializer (mirrors `ModelResolverTests`'s convention).
@Suite("LLMProviderRename")
struct LLMProviderRenameTests {
    private func config(
        providers: [String: LLMProviderConfig],
        models: [String: ModelAliasConfig] = [:],
        defaultAlias: String = "auto"
    ) -> LLMConfig {
        LLMConfig(
            provider: .claudeCLI, claude: .default, openai: .default, pricing: [:],
            providers: providers, models: models, defaultAlias: defaultAlias, defaultProviderName: nil
        )
    }

    // MARK: - Successful rename

    @Test("renames the providers entry itself, keeping its definition intact")
    func renamesProviderEntry() throws {
        let original = config(providers: ["old": .claudeCLI(ClaudeBackendConfig(cliPath: "/opt/homebrew/bin/claude"))])
        let applied = try LLMProviderRename.rename(config: original, from: "old", to: "new")

        #expect(applied.config.providers["old"] == nil)
        #expect(applied.config.providers["new"] == .claudeCLI(ClaudeBackendConfig(cliPath: "/opt/homebrew/bin/claude")))
    }

    @Test("rewrites every llm.models alias referencing the old provider name by its structured object form")
    func rewritesModelsReferencingRenamedProviderObjectForm() throws {
        let original = config(
            providers: ["old": .claudeCLI(.default), "other": .claudeCLI(.default)],
            models: [
                "auto": ModelAliasConfig(provider: "old", model: "claude-haiku-4-5-20251001"),
                "premium": ModelAliasConfig(provider: "old", model: "claude-sonnet-5", effort: "high", timeoutSeconds: 300),
                "unrelated": ModelAliasConfig(provider: "other", model: "claude-haiku-4-5-20251001")
            ]
        )
        let applied = try LLMProviderRename.rename(config: original, from: "old", to: "new")

        #expect(applied.config.models["auto"] == ModelAliasConfig(provider: "new", model: "claude-haiku-4-5-20251001"))
        #expect(applied.config.models["premium"] == ModelAliasConfig(provider: "new", model: "claude-sonnet-5", effort: "high", timeoutSeconds: 300))
        // Aliases referencing a different provider are untouched.
        #expect(applied.config.models["unrelated"] == ModelAliasConfig(provider: "other", model: "claude-haiku-4-5-20251001"))
    }

    @Test("rewrites an alias that was originally decoded from the provider/model short-string form")
    func rewritesModelsReferencingRenamedProviderShortForm() throws {
        // `ModelAliasConfig.parsingShortForm` unifies the short string form into the same struct
        // shape the object form decodes into -- decoding `"old/claude-haiku-4-5-20251001"` here
        // stands in for that origin without going through a full YAML round trip.
        let decodedFromShortForm = ModelAliasConfig.parsingShortForm("old/claude-haiku-4-5-20251001")
        let original = config(
            providers: ["old": .claudeCLI(.default)],
            models: ["auto": decodedFromShortForm]
        )
        #expect(original.models["auto"]?.provider == "old")

        let applied = try LLMProviderRename.rename(config: original, from: "old", to: "new")
        #expect(applied.config.models["auto"] == ModelAliasConfig(provider: "new", model: "claude-haiku-4-5-20251001"))
    }

    @Test("hands back the credential account move (old -> new) for the caller to perform")
    func returnsCredentialMoveAccounts() throws {
        let original = config(providers: ["old": .openai(.default)])
        let applied = try LLMProviderRename.rename(config: original, from: "old", to: "new")

        #expect(applied.credentialMove.from == "llm.providers.old.api_key")
        #expect(applied.credentialMove.to == "llm.providers.new.api_key")
    }

    @Test("renaming to the same name is a harmless no-op that still succeeds")
    func renameToSameNameIsNoOp() throws {
        let original = config(providers: ["claude": .claudeCLI(.default)])
        let applied = try LLMProviderRename.rename(config: original, from: "claude", to: "claude")
        #expect(applied.config == original)
    }

    // MARK: - Validation failures

    @Test("an empty new name is rejected")
    func rejectsEmptyName() throws {
        let original = config(providers: ["claude": .claudeCLI(.default)])
        #expect(throws: LLMProviderRenameError.emptyName) {
            try LLMProviderRename.rename(config: original, from: "claude", to: "")
        }
    }

    @Test("a new name violating [A-Za-z0-9_-]+ is rejected")
    func rejectsInvalidCharacters() throws {
        let original = config(providers: ["claude": .claudeCLI(.default)])
        #expect(throws: LLMProviderRenameError.invalidCharacters("my/prov")) {
            try LLMProviderRename.rename(config: original, from: "claude", to: "my/prov")
        }
    }

    @Test("a new name colliding with a different existing provider is rejected")
    func rejectsNameCollision() throws {
        let original = config(providers: ["claude": .claudeCLI(.default), "azure": .openai(.default)])
        #expect(throws: LLMProviderRenameError.nameCollision("azure")) {
            try LLMProviderRename.rename(config: original, from: "claude", to: "azure")
        }
    }

    @Test("renaming a provider that does not exist is rejected")
    func rejectsUnknownOldName() throws {
        let original = config(providers: ["claude": .claudeCLI(.default)])
        #expect(throws: LLMProviderRenameError.providerNotFound("missing")) {
            try LLMProviderRename.rename(config: original, from: "missing", to: "new")
        }
    }

    @Test("a failed rename leaves the config and models untouched (the caller never applies a thrown result)")
    func failedRenameConfigIsUnmodifiedWhenNotApplied() throws {
        let original = config(
            providers: ["claude": .claudeCLI(.default), "azure": .openai(.default)],
            models: ["auto": ModelAliasConfig(provider: "claude", model: "claude-haiku-4-5-20251001")]
        )
        #expect(throws: (any Error).self) {
            try LLMProviderRename.rename(config: original, from: "claude", to: "azure")
        }
        // The original binding is never mutated by a throwing call -- this just documents the
        // pure-function contract explicitly.
        #expect(original.providers.keys.sorted() == ["azure", "claude"])
        #expect(original.models["auto"]?.provider == "claude")
    }
}
