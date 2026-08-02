import Foundation
import Testing

@testable import Kikimi

/// Layer 1 coverage for `ModelMenuItems.build(config:)`/`aliasNames(config:)`
/// (`docs/design/44-llm-model-config.md` §8). Every test builds an `LLMConfig` directly through its
/// designated `init`, mirroring `ModelResolverTests`'s own fixture pattern.
@Suite("ModelMenuItems")
struct ModelMenuItemsTests {
    private func config(models: [String: ModelAliasConfig]) -> LLMConfig {
        LLMConfig(
            provider: .claudeCLI, claude: .default, openai: .default, pricing: [:],
            providers: ["claude": .claudeCLI(.default)], models: models, defaultAlias: "auto", defaultProviderName: nil
        )
    }

    // MARK: - aliasNames(config:)

    @Test("aliasNames is empty when llm.models defines nothing (no reserved names, §2.1)")
    func emptyWhenNoModelsDefined() {
        let names = ModelMenuItems.aliasNames(config: config(models: [:]))
        #expect(names.isEmpty)
    }

    @Test("every llm.models alias is sorted alphabetically, with no fixed lead names")
    func allAliasesAreSortedAlphabetically() {
        let names = ModelMenuItems.aliasNames(config: config(models: [
            "zeta": ModelAliasConfig(provider: "claude", model: "m1"),
            "alpha": ModelAliasConfig(provider: "claude", model: "m2"),
            "mid": ModelAliasConfig(provider: "claude", model: "m3")
        ]))
        #expect(names == ["alpha", "mid", "zeta"])
    }

    @Test("removing an alias from llm.models drops it from the candidate list")
    func candidateListFollowsAliasRemoval() {
        let withExtra = ModelMenuItems.aliasNames(config: config(models: [
            "cheap": ModelAliasConfig(provider: "claude", model: "m1")
        ]))
        #expect(withExtra == ["cheap"])

        let withoutExtra = ModelMenuItems.aliasNames(config: config(models: [:]))
        #expect(withoutExtra.isEmpty)
    }

    // MARK: - build(config:)

    @Test("build(config:) wraps aliasNames(config:) after useDefault, with no custom entry")
    func buildWrapsAliasNamesAfterDefault() {
        let candidates = ModelMenuItems.build(config: config(models: [
            "cheap": ModelAliasConfig(provider: "claude", model: "m1")
        ]))
        #expect(candidates == [.useDefault, .alias("cheap")])
    }

    @Test("build(config:) with no aliases still carries useDefault alone")
    func buildWithNoAliases() {
        let candidates = ModelMenuItems.build(config: config(models: [:]))
        #expect(candidates == [.useDefault])
    }
}
