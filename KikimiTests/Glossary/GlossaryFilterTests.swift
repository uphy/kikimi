import Testing

@testable import Kikimi

/// `docs/design/28-glossary.md` §4's 絞り込み search for the 用語集 Settings tab.
@Suite("GlossaryFilter")
struct GlossaryFilterTests {
    private let entries = [
        GlossaryEntry(term: "nekosuke", reading: "ねこすけ"),
        GlossaryEntry(term: "Acme Works", reading: ""),
        GlossaryEntry(term: "dev環境", reading: "デブ環境"),
    ]

    @Test("an empty query matches every entry")
    func emptyQueryMatchesAll() {
        #expect(GlossaryFilter.matchingIndices(in: entries, query: "") == [0, 1, 2])
    }

    @Test("a whitespace-only query is treated as empty")
    func whitespaceQueryMatchesAll() {
        #expect(GlossaryFilter.matchingIndices(in: entries, query: "   ") == [0, 1, 2])
    }

    @Test("the query is matched against the term")
    func matchesTerm() {
        #expect(GlossaryFilter.matchingIndices(in: entries, query: "neko") == [0])
    }

    @Test("the query is matched against the reading too")
    func matchesReading() {
        #expect(GlossaryFilter.matchingIndices(in: entries, query: "デブ") == [2])
    }

    @Test("matching is case-insensitive")
    func matchingIsCaseInsensitive() {
        #expect(GlossaryFilter.matchingIndices(in: entries, query: "acme") == [1])
    }

    @Test("the query is trimmed before matching")
    func queryIsTrimmed() {
        #expect(GlossaryFilter.matchingIndices(in: entries, query: "  neko  ") == [0])
    }

    @Test("indices refer to the original array, in its original order")
    func indicesReferToOriginalArray() {
        #expect(GlossaryFilter.matchingIndices(in: entries, query: "環境") == [2])
    }

    @Test("no match yields no indices")
    func noMatch() {
        #expect(GlossaryFilter.matchingIndices(in: entries, query: "存在しない用語").isEmpty)
    }

    @Test("an empty glossary yields no indices for any query")
    func emptyGlossary() {
        #expect(GlossaryFilter.matchingIndices(in: [], query: "").isEmpty)
        #expect(GlossaryFilter.matchingIndices(in: [], query: "neko").isEmpty)
    }
}
