import Foundation
import Testing

@testable import Kikimi

// MARK: - ModelMenuItems.Candidate.menuId

/// Unit tests for `ModelMenuItems.Candidate.menuId` (`Kikimi/Views/MeetingWorkspace/ModelOverrideMenu.swift`,
/// `docs/design/44-llm-model-config.md` §8). This is the only piece of `ModelOverrideMenu.swift` that is
/// `SwiftUI`-free -- everything else (`ModelOverrideMenuButton`/`ChatModelPicker`) is a `View` exercised
/// through `kikimi-verify` (レイヤ 2), not here. `ModelMenuItems.build(config:)`/`aliasNames(config:)`
/// themselves are covered by `KikimiTests/LLM/ModelMenuItemsTests.swift`.
@Suite("ModelMenuItems.Candidate.menuId")
struct ModelMenuItemsCandidateMenuIdTests {
    @Test("useDefault maps to a fixed id")
    func useDefaultId() {
        #expect(ModelMenuItems.Candidate.useDefault.menuId == "default")
    }

    @Test("alias(name) embeds the alias name so distinct aliases never collide in a ForEach")
    func aliasIdEmbedsName() {
        #expect(ModelMenuItems.Candidate.alias("auto").menuId == "alias:auto")
        #expect(ModelMenuItems.Candidate.alias("premium").menuId == "alias:premium")
        #expect(ModelMenuItems.Candidate.alias("cheap").menuId == "alias:cheap")
    }

    @Test("every candidate ModelMenuItems.build(config:) can produce has a distinct menuId (ForEach's id: requirement)")
    func allCandidatesFromBuildHaveDistinctIds() {
        let config = LLMConfig(
            provider: .claudeCLI, claude: .default, openai: .default, pricing: [:],
            providers: ["claude": .claudeCLI(.default)],
            models: [
                "auto": ModelAliasConfig(provider: "claude", model: "claude-haiku-4-5-20251001"),
                "premium": ModelAliasConfig(provider: "claude", model: "claude-sonnet-5"),
                "cheap": ModelAliasConfig(provider: "claude", model: "claude-haiku-4-5-20251001")
            ],
            defaultAlias: "auto", defaultProviderName: nil
        )
        let ids = ModelMenuItems.build(config: config).map(\.menuId)
        #expect(ids == ["default", "alias:auto", "alias:cheap", "alias:premium"])
        #expect(Set(ids).count == ids.count)
    }
}
