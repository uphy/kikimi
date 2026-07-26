import Testing

@testable import Kikimi

/// `docs/design/28-glossary.md` §1.2's bucket resolution, shared by `GlossaryRenderer` and the 用語集
/// Settings tab so both agree on what counts as uncategorized.
@Suite("GlossaryCategorization")
struct GlossaryCategorizationTests {
    private let categories = [
        GlossaryCategory(id: "person", name: "人物名"),
        GlossaryCategory(id: "env", name: "環境名")
    ]

    private func entries() -> [GlossaryEntry] {
        [
            GlossaryEntry(term: "nekosuke", reading: "ねこすけ", category: "person"),
            GlossaryEntry(term: "Acme Works", reading: "", category: nil),
            GlossaryEntry(term: "stg環境", reading: "ステージング環境", category: "env"),
            GlossaryEntry(term: "LLM", reading: "", category: ""),
            GlossaryEntry(term: "Claude", reading: "クロード", category: "   "),
            GlossaryEntry(term: "Entitlement", reading: "", category: "消えたカテゴリ")
        ]
    }

    @Test("a nil, empty, or whitespace-only category counts as uncategorized")
    func blankCategoriesAreUncategorized() {
        let indices = GlossaryCategorization.uncategorizedIndices(entries: entries(), categories: categories)

        #expect(indices.contains(1))
        #expect(indices.contains(3))
        #expect(indices.contains(4))
    }

    @Test("a category id matching no existing category degrades to uncategorized")
    func danglingCategoryIdIsUncategorized() {
        let indices = GlossaryCategorization.uncategorizedIndices(entries: entries(), categories: categories)

        #expect(indices.contains(5))
    }

    @Test("an entry in a real category is not uncategorized")
    func categorizedEntriesAreExcluded() {
        let indices = GlossaryCategorization.uncategorizedIndices(entries: entries(), categories: categories)

        #expect(!indices.contains(0))
        #expect(!indices.contains(2))
    }

    @Test("uncategorizedIndices returns original array indices, in the array's own order")
    func uncategorizedIndicesPreserveOrder() {
        let indices = GlossaryCategorization.uncategorizedIndices(entries: entries(), categories: categories)

        #expect(indices == [1, 3, 4, 5])
    }

    @Test("with no categories at all, every entry is uncategorized")
    func noCategoriesMeansEverythingIsUncategorized() {
        let indices = GlossaryCategorization.uncategorizedIndices(entries: entries(), categories: [])

        #expect(indices == Array(entries().indices))
    }

    @Test("indices(in:) returns only the entries of that exact category, in original order")
    func indicesInCategory() {
        #expect(GlossaryCategorization.indices(entries: entries(), in: "person") == [0])
        #expect(GlossaryCategorization.indices(entries: entries(), in: "env") == [2])
    }

    @Test("indices(in:) is empty for an unknown id, or for an empty glossary")
    func indicesInUnknownCategory() {
        #expect(GlossaryCategorization.indices(entries: entries(), in: "存在しない").isEmpty)
        #expect(GlossaryCategorization.indices(entries: [], in: "person").isEmpty)
    }

    /// Both functions trim the entry's category, so a hand-edited `category: " person "` lands in
    /// exactly one bucket. Comparing untrimmed in one and trimmed in the other would make such an entry
    /// belong to no bucket at all, vanishing from both the prompt and the UI.
    @Test("a padded category id resolves to that category, not to uncategorized")
    func paddedCategoryIdResolvesConsistently() {
        let padded = [GlossaryEntry(term: "nekosuke", reading: "ねこすけ", category: "  person  ")]

        #expect(GlossaryCategorization.indices(entries: padded, in: "person") == [0])
        #expect(GlossaryCategorization.uncategorizedIndices(entries: padded, categories: categories).isEmpty)
    }

    @Test("resolvedCategoryId returns the trimmed id, or nil when blank or unknown")
    func resolvedCategoryId() {
        let knownIds: Set<String> = ["person"]

        #expect(
            GlossaryCategorization.resolvedCategoryId(
                of: GlossaryEntry(term: "t", reading: "", category: " person "),
                knownIds: knownIds
            ) == "person"
        )
        #expect(
            GlossaryCategorization.resolvedCategoryId(
                of: GlossaryEntry(term: "t", reading: "", category: "unknown"),
                knownIds: knownIds
            ) == nil
        )
        #expect(
            GlossaryCategorization.resolvedCategoryId(
                of: GlossaryEntry(term: "t", reading: "", category: nil),
                knownIds: knownIds
            ) == nil
        )
    }
}
