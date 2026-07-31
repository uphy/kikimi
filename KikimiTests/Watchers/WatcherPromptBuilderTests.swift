import Foundation
import Testing

@testable import Kikimi

/// Layer 1 coverage for `WatcherPromptBuilder` (`docs/design/05-watcher-runner.md` §6): the
/// `{{state}}`/`{{summary}}`/`{{recent_segments}}` placeholder text each substitution resolves to,
/// and the single-pass expansion `buildUserPrompt(template:stateText:summaryMarkdown:recentSegmentsText:)`
/// performs over a Watcher's `# User` section.
@Suite("WatcherPromptBuilder")
struct WatcherPromptBuilderTests {
    // MARK: - stateText(for:stateMode:)

    @Test("snapshot mode's state text is always empty, regardless of the state passed in")
    func snapshotModeIsAlwaysEmpty() {
        #expect(WatcherPromptBuilder.stateText(for: nil, stateMode: .snapshot) == "")
        #expect(
            WatcherPromptBuilder.stateText(for: .object([.init(key: "note", value: .string("x"))]), stateMode: .snapshot) == ""
        )
    }

    @Test("cumulative mode with no state falls back to \"{}\"")
    func cumulativeModeNilStateFallsBackToEmptyObject() {
        #expect(WatcherPromptBuilder.stateText(for: nil, stateMode: .cumulative) == "{}")
    }

    @Test("appendOnly mode with no state falls back to \"{}\"")
    func appendOnlyModeNilStateFallsBackToEmptyObject() {
        #expect(WatcherPromptBuilder.stateText(for: nil, stateMode: .appendOnly) == "{}")
    }

    @Test("cumulative mode with a state renders its pretty-printed JSON")
    func cumulativeModeWithStateRendersPrettyJSON() {
        let state = JSONValue.object([.init(key: "note", value: .string("hello"))])
        #expect(WatcherPromptBuilder.stateText(for: state, stateMode: .cumulative) == state.serialize(pretty: true))
        #expect(WatcherPromptBuilder.stateText(for: state, stateMode: .cumulative).contains("\"note\""))
    }

    @Test("appendOnly mode with a state renders its pretty-printed JSON")
    func appendOnlyModeWithStateRendersPrettyJSON() {
        let state = JSONValue.object([.init(key: "count", value: .int(3))])
        #expect(WatcherPromptBuilder.stateText(for: state, stateMode: .appendOnly) == state.serialize(pretty: true))
    }

    // MARK: - recentSegmentsText(_:)

    @Test("an empty segment list renders as an empty string")
    func emptySegmentListRendersEmpty() {
        #expect(WatcherPromptBuilder.recentSegmentsText([]) == "")
    }

    @Test("a single segment renders via SummaryPromptBuilder.formatLine's \"seg_XXXXX (speaker): text\" format")
    func singleSegmentUsesSharedLineFormat() {
        let segment = WatcherSegmentInput(id: "seg_00001", startMs: 0, speaker: .mic, text: "こんにちは")
        let expected = SummaryPromptBuilder.formatLine(id: "seg_00001", speaker: .mic, text: "こんにちは")
        #expect(WatcherPromptBuilder.recentSegmentsText([segment]) == expected)
        #expect(WatcherPromptBuilder.recentSegmentsText([segment]) == "seg_00001 (mic): こんにちは")
    }

    @Test("multiple segments are joined one per line, in the given order")
    func multipleSegmentsAreJoinedOnePerLineInOrder() {
        let segments = [
            WatcherSegmentInput(id: "seg_00001", startMs: 0, speaker: .mic, text: "最初の発言"),
            WatcherSegmentInput(id: "seg_00002", startMs: 1_000, speaker: .system, text: "了解しました")
        ]
        #expect(
            WatcherPromptBuilder.recentSegmentsText(segments)
                == "seg_00001 (mic): 最初の発言\nseg_00002 (system): 了解しました"
        )
    }

    // MARK: - buildUserPrompt(template:stateText:summaryMarkdown:recentSegmentsText:)

    @Test("a template with no placeholder tokens is returned unchanged")
    func templateWithNoTokensIsUnchanged() {
        let result = WatcherPromptBuilder.buildUserPrompt(
            template: "プレーンなテキストです。",
            stateText: "STATE",
            summaryMarkdown: "SUMMARY",
            recentSegmentsText: "SEGMENTS"
        )
        #expect(result == "プレーンなテキストです。")
    }

    @Test("all three tokens are substituted, regardless of their order in the template")
    func allThreeTokensAreSubstituted() {
        let result = WatcherPromptBuilder.buildUserPrompt(
            template: "recent:\n{{recent_segments}}\n\nsummary:\n{{summary}}\n\nstate:\n{{state}}",
            stateText: "STATE",
            summaryMarkdown: "SUMMARY",
            recentSegmentsText: "SEGMENTS"
        )
        #expect(result == "recent:\nSEGMENTS\n\nsummary:\nSUMMARY\n\nstate:\nSTATE")
    }

    @Test("an unrecognized {{...}}-shaped token is left untouched (plain string replacement, not Mustache)")
    func unrecognizedTokenIsLeftUntouched() {
        let result = WatcherPromptBuilder.buildUserPrompt(
            template: "{{state}} and {{something_else}}",
            stateText: "STATE",
            summaryMarkdown: "SUMMARY",
            recentSegmentsText: "SEGMENTS"
        )
        #expect(result == "STATE and {{something_else}}")
    }

    @Test("repeated occurrences of the same token are all substituted")
    func repeatedOccurrencesOfSameTokenAreAllSubstituted() {
        let result = WatcherPromptBuilder.buildUserPrompt(
            template: "{{summary}} / {{summary}}",
            stateText: "STATE",
            summaryMarkdown: "SUMMARY",
            recentSegmentsText: "SEGMENTS"
        )
        #expect(result == "SUMMARY / SUMMARY")
    }

    /// The single-pass rationale spelled out in `buildUserPrompt`'s doc comment: if the *replacement*
    /// text for one token happens to itself contain another token's literal text (e.g. a Watcher's
    /// state JSON stores the string `"{{summary}}"`), a naive sequence of three
    /// `replacingOccurrences(of:with:)` calls would wrongly re-expand it on a later pass. Scanning the
    /// original template once must leave substituted text untouched.
    @Test("a replacement value that itself contains another token's literal text is not re-expanded")
    func substitutedTextContainingAnotherTokenIsNotReExpanded() {
        let result = WatcherPromptBuilder.buildUserPrompt(
            template: "{{state}} then {{summary}}",
            stateText: "state holds literal {{summary}} text",
            summaryMarkdown: "REAL SUMMARY",
            recentSegmentsText: "SEGMENTS"
        )
        #expect(result == "state holds literal {{summary}} text then REAL SUMMARY")
    }

    @Test("empty replacement text collapses the token to nothing, without disturbing surrounding text")
    func emptyReplacementTextCollapsesToNothing() {
        let result = WatcherPromptBuilder.buildUserPrompt(
            template: "before[{{state}}]after",
            stateText: "",
            summaryMarkdown: "SUMMARY",
            recentSegmentsText: "SEGMENTS"
        )
        #expect(result == "before[]after")
    }
}
