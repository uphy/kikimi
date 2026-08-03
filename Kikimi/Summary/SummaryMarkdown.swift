import Foundation

// MARK: - SummaryMarkdown

/// A rendered summary, split into the two panes the Summary tab shows
/// (`docs/design/47-summary-split-pane.md` §2.2).
///
/// The split exists because the two halves have different reading patterns: the top is *state*
/// (overview/decisions/action items, rewritten in place by every patch) and wants to stay visible,
/// while `topics` is a *log* that grows chronologically and wants to be followed at the bottom.
///
/// `topics == nil` means "this template could not be split" (§3.2/§3.3) -- the Summary tab then
/// falls back to the single-pane layout it had before design 47. Nothing else in the app cares:
/// every consumer outside the Summary tab goes through `joined`.
struct SummaryMarkdown: Sendable, Equatable {
    /// The meeting-state half (title/overview/participants/decisions/action items). Holds the whole
    /// document when the template could not be split.
    var top: String

    /// The 議事詳細 half, from its heading line to the end of the document. `nil` when the template
    /// could not be split.
    var topics: String?

    /// What gets written to `summary.md`. Byte-for-byte identical to rendering the template without
    /// splitting it -- `SummaryRenderer.renderSplit` only keeps a split whose halves concatenate back
    /// to the unsplit render (§3.3), so copy / chat context / Wiki export are unaffected by design 47.
    var joined: String { topics.map { top + $0 } ?? top }
}
