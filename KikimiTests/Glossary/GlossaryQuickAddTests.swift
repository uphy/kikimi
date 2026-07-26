import Testing

@testable import Kikimi

/// The メニューバー "用語を登録…" quick-add form's pure input normalization
/// (`Kikimi/Glossary/GlossaryQuickAdd.swift`).
@Suite("GlossaryQuickAdd")
struct GlossaryQuickAddTests {
    @Test("a blank term is rejected, even if only whitespace")
    func blankTermIsRejected() {
        #expect(GlossaryQuickAdd.makeEntry(term: "", reading: "", categoryId: nil) == nil)
        #expect(GlossaryQuickAdd.makeEntry(term: "   ", reading: "", categoryId: nil) == nil)
        #expect(GlossaryQuickAdd.makeEntry(term: "\n\t", reading: "", categoryId: "person") == nil)
    }

    @Test("term and reading are trimmed of surrounding whitespace")
    func termAndReadingAreTrimmed() {
        let entry = GlossaryQuickAdd.makeEntry(term: "  nekosuke  ", reading: "  ねこすけ  ", categoryId: nil)

        #expect(entry?.term == "nekosuke")
        #expect(entry?.reading == "ねこすけ")
    }

    @Test("reading is optional and defaults to an empty string")
    func readingIsOptional() {
        let entry = GlossaryQuickAdd.makeEntry(term: "Acme Works", reading: "", categoryId: nil)

        #expect(entry?.term == "Acme Works")
        #expect(entry?.reading == "")
    }

    @Test("a nil categoryId produces an uncategorized entry")
    func nilCategoryIsUncategorized() {
        let entry = GlossaryQuickAdd.makeEntry(term: "stg環境", reading: "ステージング環境", categoryId: nil)

        #expect(entry?.category == nil)
    }

    @Test("a non-nil categoryId is passed through verbatim, unresolved")
    func categoryIdIsPassedThrough() {
        let entry = GlossaryQuickAdd.makeEntry(term: "stg環境", reading: "ステージング環境", categoryId: "env")

        #expect(entry?.category == "env")
    }
}
