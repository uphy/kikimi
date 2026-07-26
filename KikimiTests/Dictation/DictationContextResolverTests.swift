import Testing

@testable import Kikimi

/// `docs/design/25-dictation-mode.md` §14.6 layer 1: every `DictationContextResolver.resolve`
/// pattern, table-driven since it is a pure function.
@Suite("DictationContextResolver")
struct DictationContextResolverTests {
    @Test("global empty + apps empty -> nil")
    func bothEmptyReturnsNil() {
        let config = DictationContextConfig(global: "", apps: [])

        #expect(DictationContextResolver.resolve(bundleID: "com.example.app", config: config) == nil)
    }

    @Test("global only (no matching app entry) -> global verbatim")
    func globalOnly() {
        let config = DictationContextConfig(global: "共通ルール", apps: [])

        #expect(DictationContextResolver.resolve(bundleID: "com.example.app", config: config) == "共通ルール")
    }

    @Test("app only (global empty, bundleID matches) -> app context prefixed with the priority header")
    func appOnly() {
        let config = DictationContextConfig(
            global: "",
            apps: [DictationAppContext(bundleID: "com.example.app", context: "Slack向けルール")]
        )

        #expect(
            DictationContextResolver.resolve(bundleID: "com.example.app", config: config)
                == "\(DictationContextResolver.appContextHeader)\nSlack向けルール"
        )
    }

    @Test("both present and matching -> joined global first, then the app context prefixed with the priority header")
    func bothJoinedInGlobalThenAppOrder() {
        let config = DictationContextConfig(
            global: "共通ルール",
            apps: [DictationAppContext(bundleID: "com.example.app", context: "Slack向けルール")]
        )

        #expect(
            DictationContextResolver.resolve(bundleID: "com.example.app", config: config)
                == "共通ルール\n\n\(DictationContextResolver.appContextHeader)\nSlack向けルール"
        )
    }

    @Test("bundleID present but does not match any registered app -> global only")
    func bundleIDMismatchFallsBackToGlobalOnly() {
        let config = DictationContextConfig(
            global: "共通ルール",
            apps: [DictationAppContext(bundleID: "com.example.app", context: "Slack向けルール")]
        )

        #expect(DictationContextResolver.resolve(bundleID: "com.other.app", config: config) == "共通ルール")
    }

    @Test("bundleID nil (capture failure) -> global only, app entries are never consulted")
    func nilBundleIDFallsBackToGlobalOnly() {
        let config = DictationContextConfig(
            global: "共通ルール",
            apps: [DictationAppContext(bundleID: "com.example.app", context: "Slack向けルール")]
        )

        #expect(DictationContextResolver.resolve(bundleID: nil, config: config) == "共通ルール")
    }

    @Test("whitespace-only global and app context are treated as empty")
    func whitespaceOnlySectionsAreTreatedAsEmpty() {
        let config = DictationContextConfig(
            global: "  \n  ",
            apps: [DictationAppContext(bundleID: "com.example.app", context: "\n\t")]
        )

        #expect(DictationContextResolver.resolve(bundleID: "com.example.app", config: config) == nil)
    }

    @Test("multiple app entries with the same bundleID: the first one wins")
    func duplicateBundleIDPrefersFirstMatch() {
        let config = DictationContextConfig(
            global: "",
            apps: [
                DictationAppContext(bundleID: "com.example.app", context: "first"),
                DictationAppContext(bundleID: "com.example.app", context: "second")
            ]
        )

        #expect(
            DictationContextResolver.resolve(bundleID: "com.example.app", config: config)
                == "\(DictationContextResolver.appContextHeader)\nfirst"
        )
    }

    // MARK: - glossary (`docs/design/28-glossary.md` §2, formerly §15/R19)
    //
    // The glossary is no longer part of `DictationContextConfig` -- it is a separate `resolve(...)`
    // parameter now (`GlossaryEntry`/`GlossaryRenderer` moved to `Kikimi/Config/GlossaryConfig.swift`/
    // `Kikimi/Glossary/GlossaryRenderer.swift`, shared with meeting-transcript refinement).

    @Test("glossary only (global/app empty) -> the rendered glossary block verbatim")
    func glossaryOnly() {
        let config = DictationContextConfig(global: "", apps: [])
        let glossary = [GlossaryEntry(term: "nekosuke", reading: "ねこすけ")]

        #expect(
            DictationContextResolver.resolve(bundleID: nil, config: config, glossary: glossary)
                == GlossaryRenderer.render(entries: glossary)
        )
    }

    @Test("global, glossary, and a matching app context are joined in that order")
    func globalGlossaryAndAppAreJoinedInOrder() {
        let config = DictationContextConfig(
            global: "共通ルール",
            apps: [DictationAppContext(bundleID: "com.example.app", context: "Slack向けルール")]
        )
        let glossary = [GlossaryEntry(term: "nekosuke", reading: "ねこすけ")]

        let glossaryBlock = GlossaryRenderer.render(entries: glossary)!
        #expect(
            DictationContextResolver.resolve(bundleID: "com.example.app", config: config, glossary: glossary)
                == "共通ルール\n\n\(glossaryBlock)\n\n\(DictationContextResolver.appContextHeader)\nSlack向けルール"
        )
    }

    @Test("a glossary whose only entry has a blank term contributes nothing")
    func glossaryWithOnlyBlankTermsContributesNothing() {
        let config = DictationContextConfig(global: "共通ルール", apps: [])
        let glossary = [GlossaryEntry(term: "  ", reading: "何か")]

        #expect(DictationContextResolver.resolve(bundleID: nil, config: config, glossary: glossary) == "共通ルール")
    }

    @Test("glossaryCategories are passed through, so the injected block is the grouped rendering")
    func glossaryCategoriesAreGrouped() {
        let config = DictationContextConfig(global: "共通ルール", apps: [])
        let glossary = [GlossaryEntry(term: "nekosuke", reading: "ねこすけ", category: "person")]
        let categories = [GlossaryCategory(id: "person", name: "人物名")]

        let glossaryBlock = GlossaryRenderer.render(entries: glossary, categories: categories)!
        #expect(glossaryBlock.contains("## 人物名"), "sanity: the fixture actually exercises grouping")
        #expect(
            DictationContextResolver.resolve(
                bundleID: nil,
                config: config,
                glossary: glossary,
                glossaryCategories: categories
            ) == "共通ルール\n\n\(glossaryBlock)"
        )
    }

    @Test("glossaryCategories defaults to an empty list, preserving the flat rendering")
    func glossaryCategoriesDefaultsToEmptyList() {
        let config = DictationContextConfig(global: "", apps: [])
        let glossary = [GlossaryEntry(term: "nekosuke", reading: "ねこすけ", category: "person")]

        #expect(
            DictationContextResolver.resolve(bundleID: nil, config: config, glossary: glossary)
                == GlossaryRenderer.render(entries: glossary)
        )
    }

    @Test("glossary parameter defaults to empty, so omitting it behaves exactly like passing []")
    func glossaryDefaultsToEmpty() {
        let config = DictationContextConfig(global: "共通ルール", apps: [])

        #expect(DictationContextResolver.resolve(bundleID: nil, config: config) == "共通ルール")
    }
}
