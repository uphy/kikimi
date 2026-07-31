import Testing

@testable import Kikimi

/// `docs/design/25-dictation-mode.md` §14.6 layer 1 (resignatured by
/// `docs/design/42-prompt-overrides.md` §4.2/§9.2): every `DictationContextResolver.resolve`
/// pattern, table-driven since it is a pure function. Bundle-id matching itself moved to
/// `DictationController` (§7.2), so these tests only exercise string combination: `globalBody` /
/// `appBody` are passed in already resolved.
@Suite("DictationContextResolver")
struct DictationContextResolverTests {
    @Test("globalBody empty + appBody nil -> nil")
    func bothEmptyReturnsNil() {
        #expect(DictationContextResolver.resolve(globalBody: "", appBody: nil) == nil)
    }

    @Test("globalBody only (appBody nil) -> globalBody verbatim")
    func globalOnly() {
        #expect(DictationContextResolver.resolve(globalBody: "共通ルール", appBody: nil) == "共通ルール")
    }

    @Test("appBody only (globalBody empty) -> app body prefixed with the priority header")
    func appOnly() {
        #expect(
            DictationContextResolver.resolve(globalBody: "", appBody: "Slack向けルール")
                == "\(DictationContextResolver.appContextHeader)\nSlack向けルール"
        )
    }

    @Test("both present -> joined global first, then the app body prefixed with the priority header")
    func bothJoinedInGlobalThenAppOrder() {
        #expect(
            DictationContextResolver.resolve(globalBody: "共通ルール", appBody: "Slack向けルール")
                == "共通ルール\n\n\(DictationContextResolver.appContextHeader)\nSlack向けルール"
        )
    }

    @Test("appBody nil (no matching bundle id) -> global only")
    func nilAppBodyFallsBackToGlobalOnly() {
        #expect(DictationContextResolver.resolve(globalBody: "共通ルール", appBody: nil) == "共通ルール")
    }

    @Test("whitespace-only globalBody and appBody are treated as empty")
    func whitespaceOnlySectionsAreTreatedAsEmpty() {
        #expect(DictationContextResolver.resolve(globalBody: "  \n  ", appBody: "\n\t") == nil)
    }

    @Test("an empty (trimmed) appBody contributes nothing even when globalBody is non-empty")
    func emptyAppBodyContributesNothing() {
        #expect(DictationContextResolver.resolve(globalBody: "共通ルール", appBody: "   ") == "共通ルール")
    }

    // MARK: - glossary (`docs/design/28-glossary.md` §2, formerly §15/R19)
    //
    // The glossary is not part of the resolver's own inputs -- it is a separate `resolve(...)`
    // parameter (`GlossaryEntry`/`GlossaryRenderer` live in `Kikimi/Config/GlossaryConfig.swift`/
    // `Kikimi/Glossary/GlossaryRenderer.swift`, shared with meeting-transcript refinement).

    @Test("glossary only (globalBody/appBody empty) -> the rendered glossary block verbatim")
    func glossaryOnly() {
        let glossary = [GlossaryEntry(term: "nekosuke", reading: "ねこすけ")]

        #expect(
            DictationContextResolver.resolve(globalBody: "", appBody: nil, glossary: glossary)
                == GlossaryRenderer.render(entries: glossary)
        )
    }

    @Test("globalBody, glossary, and appBody are joined in that order")
    func globalGlossaryAndAppAreJoinedInOrder() {
        let glossary = [GlossaryEntry(term: "nekosuke", reading: "ねこすけ")]

        let glossaryBlock = GlossaryRenderer.render(entries: glossary)!
        #expect(
            DictationContextResolver.resolve(globalBody: "共通ルール", appBody: "Slack向けルール", glossary: glossary)
                == "共通ルール\n\n\(glossaryBlock)\n\n\(DictationContextResolver.appContextHeader)\nSlack向けルール"
        )
    }

    @Test("a glossary whose only entry has a blank term contributes nothing")
    func glossaryWithOnlyBlankTermsContributesNothing() {
        let glossary = [GlossaryEntry(term: "  ", reading: "何か")]

        #expect(DictationContextResolver.resolve(globalBody: "共通ルール", appBody: nil, glossary: glossary) == "共通ルール")
    }

    @Test("glossaryCategories are passed through, so the injected block is the grouped rendering")
    func glossaryCategoriesAreGrouped() {
        let glossary = [GlossaryEntry(term: "nekosuke", reading: "ねこすけ", category: "person")]
        let categories = [GlossaryCategory(id: "person", name: "人物名")]

        let glossaryBlock = GlossaryRenderer.render(entries: glossary, categories: categories)!
        #expect(glossaryBlock.contains("## 人物名"), "sanity: the fixture actually exercises grouping")
        #expect(
            DictationContextResolver.resolve(
                globalBody: "共通ルール",
                appBody: nil,
                glossary: glossary,
                glossaryCategories: categories
            ) == "共通ルール\n\n\(glossaryBlock)"
        )
    }

    @Test("glossaryCategories defaults to an empty list, preserving the flat rendering")
    func glossaryCategoriesDefaultsToEmptyList() {
        let glossary = [GlossaryEntry(term: "nekosuke", reading: "ねこすけ", category: "person")]

        #expect(
            DictationContextResolver.resolve(globalBody: "", appBody: nil, glossary: glossary)
                == GlossaryRenderer.render(entries: glossary)
        )
    }

    @Test("glossary parameter defaults to empty, so omitting it behaves exactly like passing []")
    func glossaryDefaultsToEmpty() {
        #expect(DictationContextResolver.resolve(globalBody: "共通ルール", appBody: nil) == "共通ルール")
    }

    // MARK: - glossaryHeader (`docs/design/42-prompt-overrides.md` §2.2 "glossary-header")

    @Test("glossaryHeader defaults to GlossaryRenderer.defaultHeader")
    func glossaryHeaderDefaultsToDefaultHeader() {
        let glossary = [GlossaryEntry(term: "nekosuke", reading: "ねこすけ")]

        #expect(
            DictationContextResolver.resolve(globalBody: "", appBody: nil, glossary: glossary)
                == GlossaryRenderer.render(entries: glossary, header: GlossaryRenderer.defaultHeader)
        )
    }

    @Test("a custom glossaryHeader is passed straight through to GlossaryRenderer.render")
    func customGlossaryHeaderIsPassedThrough() {
        let glossary = [GlossaryEntry(term: "nekosuke", reading: "ねこすけ")]
        let customHeader = "# Custom Glossary Header"

        let expectedBlock = GlossaryRenderer.render(entries: glossary, header: customHeader)!
        #expect(expectedBlock.hasPrefix(customHeader))
        #expect(
            DictationContextResolver.resolve(globalBody: "", appBody: nil, glossary: glossary, glossaryHeader: customHeader)
                == expectedBlock
        )
    }
}
