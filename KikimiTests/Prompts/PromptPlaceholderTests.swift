import Foundation
import Testing

@testable import Kikimi

/// Layer 1 coverage for `PromptPlaceholder.expand` (`docs/design/42-prompt-overrides.md` §4.1): the
/// shared single-pass `{{token}}` substitution helper `WatcherPromptBuilder.buildUserPrompt` delegates
/// to (`docs/design/05-watcher-runner.md` §6).
@Suite("PromptPlaceholder")
struct PromptPlaceholderTests {
    @Test("a template with no placeholder tokens is returned unchanged")
    func templateWithNoTokensIsUnchanged() {
        let result = PromptPlaceholder.expand(
            template: "プレーンなテキストです。",
            replacements: [("{{a}}", "A"), ("{{b}}", "B")]
        )
        #expect(result == "プレーンなテキストです。")
    }

    @Test("multiple tokens are substituted in the order they appear in the template, regardless of the order given in replacements")
    func multipleTokensAreSubstitutedInTemplateOrder() {
        let result = PromptPlaceholder.expand(
            template: "second:{{b}} first:{{a}}",
            replacements: [("{{a}}", "A"), ("{{b}}", "B")]
        )
        #expect(result == "second:B first:A")
    }

    @Test("an unrecognized {{...}}-shaped token is left untouched (plain string replacement, not Mustache)")
    func unrecognizedTokenIsLeftUntouched() {
        let result = PromptPlaceholder.expand(
            template: "{{a}} and {{something_else}}",
            replacements: [("{{a}}", "A")]
        )
        #expect(result == "A and {{something_else}}")
    }

    @Test("repeated occurrences of the same token are all substituted")
    func repeatedOccurrencesOfSameTokenAreAllSubstituted() {
        let result = PromptPlaceholder.expand(
            template: "{{a}} / {{a}}",
            replacements: [("{{a}}", "A")]
        )
        #expect(result == "A / A")
    }

    /// The single-pass rationale: if the *replacement* text for one token happens to itself contain
    /// another token's literal text, a naive sequence of `replacingOccurrences(of:with:)` calls would
    /// wrongly re-expand it on a later pass. Scanning the original template once must leave substituted
    /// text untouched.
    @Test("a replacement value that itself contains another token's literal text is not re-expanded")
    func substitutedTextContainingAnotherTokenIsNotReExpanded() {
        let result = PromptPlaceholder.expand(
            template: "{{a}} then {{b}}",
            replacements: [("{{a}}", "holds literal {{b}} text"), ("{{b}}", "REAL B")]
        )
        #expect(result == "holds literal {{b}} text then REAL B")
    }

    /// Same re-expansion guard, but for a token whose *own* replacement text contains its own literal
    /// token -- the single pass must not loop back over text it already emitted.
    @Test("a replacement value that contains its own token's literal text is not re-expanded")
    func substitutedTextContainingItsOwnTokenIsNotReExpanded() {
        let result = PromptPlaceholder.expand(
            template: "before {{a}} after",
            replacements: [("{{a}}", "nested {{a}} literal")]
        )
        #expect(result == "before nested {{a}} literal after")
    }

    @Test("empty replacement text collapses the token to nothing, without disturbing surrounding text")
    func emptyReplacementTextCollapsesToNothing() {
        let result = PromptPlaceholder.expand(
            template: "before[{{a}}]after",
            replacements: [("{{a}}", "")]
        )
        #expect(result == "before[]after")
    }

    @Test("an empty replacements list returns the template unchanged")
    func emptyReplacementsListReturnsTemplateUnchanged() {
        let result = PromptPlaceholder.expand(template: "{{a}} plain text", replacements: [])
        #expect(result == "{{a}} plain text")
    }

    @Test("an empty template with a non-empty replacements list returns an empty string")
    func emptyTemplateReturnsEmptyString() {
        let result = PromptPlaceholder.expand(template: "", replacements: [("{{a}}", "A")])
        #expect(result.isEmpty)
    }
}
