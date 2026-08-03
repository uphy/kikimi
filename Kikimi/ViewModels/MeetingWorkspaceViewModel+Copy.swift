import Foundation

// MARK: - MeetingWorkspaceViewModel + Copy (`docs/design/37-transcript-markdown-copy.md` §3.2(a)/§3.3)

/// The Session Window's transcript-Markdown copy entry points (toolbar / ⌘⇧C / per-row button, §3.3)
/// and their live adapter (§3.2(a)). Split into its own file (same rationale as `+Summary.swift`/
/// `+Prep.swift`) to keep `MeetingWorkspaceViewModel.swift` under the project's `file_length` lint
/// limit.
///
/// The live adapter copies exactly what `transcriptRows`/`speakerLabels` already show on screen --
/// unlike `TranscriptMarkdownSource` (the disk adapter used by `SessionListViewModel`/`WikiExporter`),
/// it never re-reads `sessionHandle` from disk for the transcript itself, so a copy made mid-Recording
/// never drifts from what the user is currently looking at.
extension MeetingWorkspaceViewModel {
    // MARK: - Public API

    /// Copies `scope`'s document to the clipboard (§3.3's toolbar / ⌘⇧C entry points, always `.full`
    /// today for the keyboard shortcut but every `Scope` for the toolbar's menu items). `meta` is
    /// re-read from `sessionHandle` on every call (TC13) rather than using this view model's own
    /// `meta` snapshot, which can be stale mid-Recording (`recordings[]` grows as segments start).
    func copyMarkdown(scope: TranscriptMarkdownRenderer.Scope) async {
        let currentMeta = await sessionHandle.meta
        let input = TranscriptMarkdownRenderer.Input(
            meta: currentMeta,
            // `joined`, not the top pane: copying must produce the whole summary regardless of how
            // the Summary tab happens to be split (`docs/design/47-summary-split-pane.md` §6).
            summaryMarkdown: summaryMarkdown?.joined ?? "",
            lines: liveMarkdownLines()
        )
        let markdown = TranscriptMarkdownRenderer.render(input, scope: scope)
        recordCopyResult(pasteboard.writeString(markdown), rowId: nil, context: "copyMarkdown(scope:)")
    }

    /// Copies exactly one row's line (§3.3 "発言行", §4.4 format) to the clipboard. A `rowId` that
    /// doesn't match any currently-visible row (e.g. it was dropped by refinement or merged away, per
    /// the same exclusion rule `liveMarkdownLines()` applies) is a silent no-op -- there is nothing to
    /// copy and no feedback to show.
    func copyRowMarkdown(rowId: String) async {
        guard let line = liveMarkdownLines().first(where: { $0.id == rowId }) else { return }
        let currentMeta = await sessionHandle.meta
        let markdown = TranscriptMarkdownRenderer.renderLine(line, meta: currentMeta)
        recordCopyResult(pasteboard.writeString(markdown), rowId: rowId, context: "copyRowMarkdown(rowId:)")
    }

    // MARK: - Private: live adapter (§3.2(a))

    /// `transcriptRows`, filtered and mapped to `TranscriptMarkdownRenderer.Line`s exactly like the
    /// Transcript tab renders them (`TranscriptTabView.swift`'s `ForEach` filter + `displayText`), so
    /// "what's on screen" and "what gets copied" never diverge. Volatile (unconfirmed) rows are never
    /// in `transcriptRows` in the first place, so no separate exclusion is needed for those (TC12).
    private func liveMarkdownLines() -> [TranscriptMarkdownRenderer.Line] {
        transcriptRows
            .filter { !$0.state.isDroppedByRefinement && !$0.state.isMergedAway }
            .map(markdownLine(for:))
    }

    /// One row's `Line`, mirroring `TranscriptRowContentView.displayText`'s branches (minus the
    /// "🔄 " prefix `.refining` renders on screen -- design §3.2(a)/§4.3 call that a UI-only affordance,
    /// not part of the copied text) and resolving the speaker name per §4.2's table.
    private func markdownLine(for row: TranscriptRowViewModel) -> TranscriptMarkdownRenderer.Line {
        let (text, isRawFallback) = markdownBody(for: row.state, rawText: row.rawText)
        return TranscriptMarkdownRenderer.Line(
            id: row.id,
            startMs: row.startMs,
            speakerName: markdownSpeakerName(for: row),
            text: text,
            isRawFallback: isRawFallback
        )
    }

    /// `(text, isRawFallback)` for `state`, mirroring `TranscriptRowContentView.displayText`'s switch
    /// exactly (design §4.3): `.refined` renders the refined text with no marker, every other reachable
    /// case falls back to `rawText` with the `*(raw)*` marker. `.mergedInto` is unreachable here --
    /// `liveMarkdownLines()` filters `isMergedAway` rows out before this is ever called -- but the
    /// switch stays exhaustive (same convention `TranscriptRowContentView.displayText` follows).
    private func markdownBody(for state: TranscriptRowState, rawText: String) -> (text: String, isRawFallback: Bool) {
        switch state {
        case .raw, .refining, .mergedInto:
            return (rawText, true)
        case .refined(let refinedText):
            // `liveMarkdownLines()` already dropped `isDroppedByRefinement` rows (`refined("")`), so
            // `refinedText` here is always non-empty.
            return (refinedText, false)
        case .refinedFailed:
            // kikimi.md 8.5 章: refinement failure falls back to raw_text, same as the screen.
            return (rawText, true)
        }
    }

    /// §4.2's speaker-name mapping. `mic` rows never consult `speakerLabels` -- design §3.2(a)/§4.2's
    /// "`mic` セグメントは上表を通さず常に `selfName`" -- and always resolve to the configured self name.
    /// `system` rows fall back to `.systemFallback` when `speakerLabels[row.id]` is `nil` (diarization
    /// disabled, `MeetingWorkspaceViewModel+Diarization.swift`'s `recomputeSpeakerLabels()` early
    /// return), matching what `TranscriptTabView`'s `resolvedLabel ?? .systemFallback` already renders.
    /// Never returns an empty string (design §3.1's `Line.speakerName` invariant).
    private func markdownSpeakerName(for row: TranscriptRowViewModel) -> String {
        switch row.speaker {
        case .mic:
            return appConfig.data.diarization.selfName
        case .system:
            let resolved = speakerLabels[row.id] ?? .systemFallback
            return Self.markdownSpeakerName(for: resolved.label)
        }
    }

    /// `SpeakerDisplayLabel` -> Markdown speaker name (design §4.2's table). `hasOverlapMarker`/`⚠` is
    /// deliberately not consulted here (TC4): it is a screen-only "this row's attribution is uncertain"
    /// hint, not part of the copied speaker name.
    private static func markdownSpeakerName(for label: SpeakerDisplayLabel) -> String {
        switch label {
        case .systemFallback:
            return "system"
        case .recognizing, .unknown:
            return "Speaker ?"
        case .anonymous(let slotNumber):
            return "Speaker \(slotNumber)"
        case .named(let name):
            return name
        case .mixed(let primary, let secondary):
            return "\(primary) + \(secondary)"
        }
    }

    // MARK: - Private: feedback (§6/TC11)

    /// Common tail of both public entry points: on a successful pasteboard write, updates whichever
    /// published property drives the button actually clicked (§3.3's toolbar/⌘⇧C vs. per-row button
    /// are two independent controls, each showing only its own feedback -- `rowId == nil` bumps
    /// `copyFeedbackToken` (driving the toolbar checkmark, `MeetingTabView`'s `.task(id:
    /// copyFeedbackToken)`) and clears `copyFeedbackRowId` so a stale row highlight from an earlier
    /// row copy doesn't linger; `rowId != nil` sets `copyFeedbackRowId` for that row's own checkmark
    /// (`TranscriptRowContentView`'s `.task(id: copyFeedbackRowId)`) *without* bumping
    /// `copyFeedbackToken` -- copying a single row must not also flash the toolbar's "copy whole
    /// document" icon. A failed write updates neither published property -- the UI simply stays as it
    /// was -- and logs at `.error` (Logging Rules: "Processing failure or error" -> `error`).
    private func recordCopyResult(_ succeeded: Bool, rowId: String?, context: String) {
        guard succeeded else {
            logger.error(
                "Pasteboard write failed for \(context, privacy: .public) (session \(self.sessionId, privacy: .public))"
            )
            return
        }
        copyFeedbackRowId = rowId
        if rowId == nil {
            copyFeedbackToken += 1
        }
    }
}
