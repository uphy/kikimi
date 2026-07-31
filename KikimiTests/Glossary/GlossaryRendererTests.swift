import Testing

@testable import Kikimi

/// `docs/design/28-glossary.md` §2's rendering layer for the top-level `glossary` config section
/// (formerly `dictation.context.glossary` per `docs/design/25-dictation-mode.md` §15/R19, before the
/// glossary was promoted out to be shared with meeting-transcript refinement).
@Suite("GlossaryRenderer")
struct GlossaryRendererTests {
    @Test("no entries -> nil")
    func noEntriesReturnsNil() {
        #expect(GlossaryRenderer.render(entries: []) == nil)
    }

    @Test("an entry with no reading is rendered as a bare bullet")
    func entryWithoutReading() {
        let rendered = GlossaryRenderer.render(entries: [GlossaryEntry(term: "Acme Works", reading: "")])

        #expect(rendered == "\(GlossaryRenderer.defaultHeader)\n\n- Acme Works")
    }

    @Test("an entry with a reading is rendered as \"reading → term\"")
    func entryWithReading() {
        let rendered = GlossaryRenderer.render(entries: [GlossaryEntry(term: "nekosuke", reading: "ねこすけ")])

        #expect(rendered == "\(GlossaryRenderer.defaultHeader)\n\n- ねこすけ → nekosuke")
    }

    @Test("multiple entries preserve their original order, one bullet per line")
    func multipleEntriesPreserveOrder() {
        let entries = [
            GlossaryEntry(term: "nekosuke", reading: "ねこすけ"),
            GlossaryEntry(term: "dev環境", reading: "デブ環境"),
            GlossaryEntry(term: "Acme Works", reading: ""),
            GlossaryEntry(term: "Claude", reading: "クロード")
        ]

        let rendered = GlossaryRenderer.render(entries: entries)

        #expect(
            rendered == """
            \(GlossaryRenderer.defaultHeader)

            - ねこすけ → nekosuke
            - デブ環境 → dev環境
            - Acme Works
            - クロード → Claude
            """
        )
    }

    @Test("an entry whose term is blank (or whitespace-only) after trimming is skipped")
    func blankTermEntriesAreSkipped() {
        let entries = [
            GlossaryEntry(term: "", reading: "オプション不要な誤変換"),
            GlossaryEntry(term: "  \n ", reading: ""),
            GlossaryEntry(term: "Entitlement", reading: "")
        ]

        #expect(GlossaryRenderer.render(entries: entries) == "\(GlossaryRenderer.defaultHeader)\n\n- Entitlement")
    }

    @Test("if every entry's term is blank, the result is nil (not a header with no terms under it)")
    func allBlankTermsReturnsNil() {
        let entries = [GlossaryEntry(term: "", reading: ""), GlossaryEntry(term: "   ", reading: "何か")]

        #expect(GlossaryRenderer.render(entries: entries) == nil)
    }

    @Test("term/reading whitespace is trimmed before rendering")
    func termAndReadingAreTrimmed() {
        let rendered = GlossaryRenderer.render(entries: [GlossaryEntry(term: "  Claude Agent  ", reading: "  ")])

        #expect(rendered == "\(GlossaryRenderer.defaultHeader)\n\n- Claude Agent")
    }

    /// Regression guard for `docs/design/28-glossary.md` §2.1: the header must instruct substitution
    /// unconditionally, not only where STT produced an obvious 誤変換. The wording that framed the list
    /// as mis-transcription repair silently no-op'd every notation-normalization entry
    /// (「ステージング環境」→「stg環境」), because the LLM judged the reading to be a faithful transcription.
    /// Asserted on the header's meaning-bearing clauses rather than the whole string, so the prompt can
    /// still be tuned without rewriting this test.
    @Test("the header instructs substitution even when the reading was transcribed correctly")
    func headerFramesTheListAsASubstitutionRule() {
        #expect(GlossaryRenderer.defaultHeader.contains("正しく書き起こされていても"))
    }

    /// The bare-term case used to have no rule at all in the prompt -- its meaning lived only in
    /// `GlossaryEntry`'s doc comment, where no LLM could read it (§2.1).
    @Test("the header explains what a bare term (no reading) means")
    func headerExplainsBareTerms() {
        #expect(GlossaryRenderer.defaultHeader.contains("用語のみの行"))
    }

    /// Regression guard for §2.2: with the `A: B` colon format, gpt-5.4-nano emitted the *left*
    /// side of a matched row (「根建さん」→「こんけんさん」 instead of 「konkenさん」), reading the
    /// colon as "headword: gloss". The header must state the substitution direction outright.
    @Test("the header states that only the right side of the arrow may appear in the output")
    func headerStatesSubstitutionDirection() {
        #expect(GlossaryRenderer.defaultHeader.contains("「→」の右側"))
    }

    /// Regression guard for §2.2's other failure: a name with no matching row (`konken` had no
    /// reading yet) was force-matched onto a *different* entry's reading (「根建さん」→「ねこかくさん」).
    @Test("the header forbids force-matching a word that matches no row")
    func headerForbidsForceMatching() {
        #expect(GlossaryRenderer.defaultHeader.contains("無理に寄せてはいけません"))
    }

    // MARK: - categories (`docs/design/28-glossary.md` §1.2)

    private static let person = GlossaryCategory(id: "person", name: "人物名", instruction: "敬称は原文のまま残す。")
    private static let env = GlossaryCategory(id: "env", name: "環境名")

    @Test("omitting categories renders exactly the flat list it did before categories existed")
    func noCategoriesPreservesFlatRendering() {
        let entries = [
            GlossaryEntry(term: "nekosuke", reading: "ねこすけ"),
            GlossaryEntry(term: "Acme Works", reading: "")
        ]

        #expect(GlossaryRenderer.render(entries: entries, categories: []) == GlossaryRenderer.render(entries: entries))
    }

    @Test("uncategorized entries render first, bare, then each category as a ## heading in categories order")
    func uncategorizedFirstThenCategoriesInOrder() {
        let entries = [
            GlossaryEntry(term: "stg環境", reading: "ステージング環境", category: "env"),
            GlossaryEntry(term: "Acme Works", reading: ""),
            GlossaryEntry(term: "nekosuke", reading: "ねこすけ", category: "person")
        ]

        let rendered = GlossaryRenderer.render(entries: entries, categories: [Self.person, Self.env])

        #expect(
            rendered == """
            \(GlossaryRenderer.defaultHeader)

            - Acme Works

            ## 人物名
            敬称は原文のまま残す。
            - ねこすけ → nekosuke

            ## 環境名
            - ステージング環境 → stg環境
            """
        )
    }

    @Test("entries within a category keep their original array order")
    func entriesWithinACategoryPreserveOrder() {
        let entries = [
            GlossaryEntry(term: "prd環境", reading: "ぷろど環境", category: "env"),
            GlossaryEntry(term: "stg環境", reading: "ステージング環境", category: "env")
        ]

        let rendered = GlossaryRenderer.render(entries: entries, categories: [Self.env])

        #expect(rendered?.hasSuffix("## 環境名\n- ぷろど環境 → prd環境\n- ステージング環境 → stg環境") == true)
    }

    @Test("a category with no instruction renders its heading straight above its bullets")
    func categoryWithoutInstruction() {
        let entries = [GlossaryEntry(term: "stg環境", reading: "", category: "env")]

        #expect(GlossaryRenderer.render(entries: entries, categories: [Self.env]) == "\(GlossaryRenderer.defaultHeader)\n\n## 環境名\n- stg環境")
    }

    @Test("a category with no renderable entries emits nothing at all, heading included")
    func emptyCategoryEmitsNothing() {
        let entries = [GlossaryEntry(term: "nekosuke", reading: "ねこすけ", category: "person")]

        let rendered = GlossaryRenderer.render(entries: entries, categories: [Self.person, Self.env])

        #expect(rendered?.contains("環境名") != true)
    }

    @Test("a category whose only entries have blank terms emits nothing")
    func categoryOfBlankTermsEmitsNothing() {
        let entries = [GlossaryEntry(term: "   ", reading: "何か", category: "env")]

        #expect(GlossaryRenderer.render(entries: entries, categories: [Self.env]) == nil)
    }

    @Test("an entry whose category no longer exists renders as uncategorized, not dropped")
    func danglingCategoryIdRendersAsUncategorized() {
        let entries = [GlossaryEntry(term: "Entitlement", reading: "", category: "消えたカテゴリ")]

        #expect(GlossaryRenderer.render(entries: entries, categories: [Self.person]) == "\(GlossaryRenderer.defaultHeader)\n\n- Entitlement")
    }

    @Test("an entry with a blank category string renders as uncategorized")
    func blankCategoryStringRendersAsUncategorized() {
        let entries = [GlossaryEntry(term: "LLM", reading: "", category: "  ")]

        #expect(GlossaryRenderer.render(entries: entries, categories: [Self.person]) == "\(GlossaryRenderer.defaultHeader)\n\n- LLM")
    }

    @Test("blank-term entries inside a category are still skipped, without emptying the category")
    func blankTermsWithinACategoryAreSkipped() {
        let entries = [
            GlossaryEntry(term: "", reading: "未入力の行", category: "env"),
            GlossaryEntry(term: "stg環境", reading: "", category: "env")
        ]

        #expect(GlossaryRenderer.render(entries: entries, categories: [Self.env]) == "\(GlossaryRenderer.defaultHeader)\n\n## 環境名\n- stg環境")
    }

    @Test("if every entry is blank across all buckets, the result is nil")
    func allBlankAcrossBucketsReturnsNil() {
        let entries = [
            GlossaryEntry(term: "  ", reading: ""),
            GlossaryEntry(term: "", reading: "", category: "env")
        ]

        #expect(GlossaryRenderer.render(entries: entries, categories: [Self.env]) == nil)
    }

    // MARK: - header (`docs/design/42-prompt-overrides.md` §2.2/§4.2 "glossary-header")

    @Test("omitting header renders with defaultHeader, same as passing it explicitly")
    func omittingHeaderMatchesExplicitDefaultHeader() {
        let entries = [GlossaryEntry(term: "nekosuke", reading: "ねこすけ")]

        #expect(
            GlossaryRenderer.render(entries: entries)
                == GlossaryRenderer.render(entries: entries, header: GlossaryRenderer.defaultHeader)
        )
    }

    @Test("a custom header replaces defaultHeader, but bullets/category rendering stay unaffected")
    func customHeaderReplacesDefaultHeader() {
        let entries = [GlossaryEntry(term: "nekosuke", reading: "ねこすけ")]
        let customHeader = "# Custom Glossary Header\n\nカスタムの置換ルール本文。"

        let rendered = GlossaryRenderer.render(entries: entries, header: customHeader)

        #expect(rendered == "\(customHeader)\n\n- ねこすけ → nekosuke")
        #expect(rendered?.contains(GlossaryRenderer.defaultHeader) != true)
    }

    @Test("a custom header still precedes category headings and bullets")
    func customHeaderWithCategories() {
        let entries = [GlossaryEntry(term: "stg環境", reading: "ステージング環境", category: "env")]
        let customHeader = "# Custom Glossary Header"

        let rendered = GlossaryRenderer.render(entries: entries, categories: [Self.env], header: customHeader)

        #expect(rendered == "\(customHeader)\n\n## 環境名\n- ステージング環境 → stg環境")
    }
}
