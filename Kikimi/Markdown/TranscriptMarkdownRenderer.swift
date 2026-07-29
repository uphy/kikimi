import Foundation

// MARK: - TranscriptMarkdownRenderer

/// Pure rendering logic shared by the Wiki export (`docs/design/08-wiki-export.md`, kikimi.md 11 章)
/// and the transcript Markdown copy feature (`docs/design/37-transcript-markdown-copy.md` §3.1/§4,
/// TC1). Every function here is side-effect-free and takes plain, already-loaded values -- never
/// `SessionHandle`/`AppConfig`/an actor directly -- so frontmatter shape, wall-clock conversion,
/// raw-fallback marker placement, and empty-section omission are all unit-testable without any
/// actor/filesystem involvement.
///
/// This type does not resolve speaker display names or decide which segments to include -- that is
/// each caller's adapter's job (the live `MeetingWorkspaceViewModel` path and the disk-backed
/// `TranscriptMarkdownSource` path, design §3.2). By the time a `Line` reaches this renderer, its
/// `speakerName`/`text`/`isRawFallback` are already final; this type only orders and formats them.
enum TranscriptMarkdownRenderer {
    /// One transcript line, with its speaker name already resolved (design §3.1). Which adapter
    /// produced it (live vs. disk) is not tracked here.
    struct Line: Sendable, Equatable {
        /// The live adapter uses `TranscriptRowViewModel.id`; the disk adapter uses
        /// `RefinedSegment.id`/`TranscriptSegment.id`. Used only to break ties when two lines share
        /// the same `startMs` (see `sortedLines(_:)` below) -- it never appears in the rendered
        /// output.
        var id: String
        var startMs: Int
        /// Already mapped through design §4.2's table. Never empty.
        var speakerName: String
        var text: String
        /// `true` for a refinement failure or a not-yet-refined line (design §4.3); appends
        /// `rawFallbackMarker` to the rendered line.
        var isRawFallback: Bool
    }

    /// Everything `render(_:scope:)` needs, already gathered by the caller's adapter.
    struct Input: Sendable, Equatable {
        var meta: SessionMeta
        /// `summary.md`'s already-rendered text, or `""` if the session never got as far as a first
        /// summary update (design §4.3/TC14: an empty string omits the `## サマリ` section entirely).
        var summaryMarkdown: String
        /// Not required to be `startMs`-sorted -- `render(_:scope:)` sorts internally (design §3.1),
        /// so callers never need to pre-sort.
        var lines: [Line]
    }

    /// Which sections of the document to render (design §4.1, TC6). `full` is the only scope that
    /// includes frontmatter -- a fragment with frontmatter mixed in would corrupt Obsidian's
    /// properties pane when pasted alongside other text.
    enum Scope: Sendable {
        case full
        case transcript
        case summary
    }

    /// Marker appended to a transcript line that fell back to raw text (refinement failure or
    /// not-yet-refined, design §4.3).
    static let rawFallbackMarker = " *(raw)*"

    /// Fixed frontmatter `tags:` value (kikimi.md 11 章's sample; not currently configurable).
    private static let frontmatterTags = "[meeting, transcript]"

    // MARK: - render

    /// Renders `scope`'s document (design §4.1): frontmatter (only for `.full`) + `# title` +
    /// `## サマリ` + `## 書き起こし`, each present only if `scope` includes it *and* it has content
    /// (TC14: an empty `summaryMarkdown` or an empty `lines` omits its heading entirely, not just its
    /// body). Always ends with exactly one trailing newline.
    static func render(_ input: Input, scope: Scope) -> String {
        let includeFrontmatter: Bool
        let includeSummary: Bool
        let includeTranscript: Bool
        switch scope {
        case .full:
            includeFrontmatter = true
            includeSummary = true
            includeTranscript = true
        case .transcript:
            includeFrontmatter = false
            includeSummary = false
            includeTranscript = true
        case .summary:
            includeFrontmatter = false
            includeSummary = true
            includeTranscript = false
        }

        let meta = input.meta
        var blocks: [String] = []

        if includeFrontmatter {
            blocks.append(frontmatterBlock(for: meta))
        }

        blocks.append("# \(meta.title)")

        if includeSummary, !input.summaryMarkdown.isEmpty {
            blocks.append("## サマリ\n\n\(input.summaryMarkdown)")
        }

        if includeTranscript {
            let orderedLines = sortedLines(input.lines)
            if !orderedLines.isEmpty {
                let referenceDate = self.referenceDate(for: meta)
                let body = orderedLines
                    .map { lineBody($0, meta: meta, referenceDate: referenceDate) }
                    .joined(separator: "\n\n")
                blocks.append("## 書き起こし\n\n\(body)")
            }
        }

        return blocks.joined(separator: "\n\n") + "\n"
    }

    /// Renders a single line in exactly the same format `render(_:scope:)` uses inside
    /// `## 書き起こし` (design §4.4), with **no** trailing newline -- unlike `render(_:scope:)`, this
    /// is meant to be pasted as a standalone fragment, and a trailing blank line would accumulate if
    /// the caller pastes several rows in a row.
    static func renderLine(_ line: Line, meta: SessionMeta) -> String {
        lineBody(line, meta: meta, referenceDate: referenceDate(for: meta))
    }

    /// `**HH:MM:SS {speakerName}** {text}`, with `rawFallbackMarker` appended when
    /// `line.isRawFallback` (design §4.2/§4.4). Shared by `render(_:scope:)`'s transcript section and
    /// `renderLine(_:meta:)` so the two can never drift.
    private static func lineBody(_ line: Line, meta: SessionMeta, referenceDate: Date) -> String {
        let wallClock = wallClockDate(startMs: line.startMs, recordings: meta.recordings, fallback: referenceDate)
        let time = timeFormatter.string(from: wallClock)
        let marker = line.isRawFallback ? rawFallbackMarker : ""
        return "**\(time) \(line.speakerName)** \(line.text)\(marker)"
    }

    /// `startMs` ascending, ties broken by `Line.id` ascending (design §3.1). Swift's `sorted` is not
    /// a stable sort, so dropping the `id` tiebreak would let same-`startMs` lines (e.g. a mic line
    /// and a system line landing at the same millisecond) swap order nondeterministically between
    /// runs -- exactly the regression `WikiExportRenderer.transcriptLines`/
    /// `TranscriptRowList.isOrderedBefore` already guard against.
    private static func sortedLines(_ lines: [Line]) -> [Line] {
        lines.sorted { lhs, rhs in
            lhs.startMs != rhs.startMs ? lhs.startMs < rhs.startMs : lhs.id < rhs.id
        }
    }

    private static func frontmatterBlock(for meta: SessionMeta) -> String {
        let dateLabel = frontmatterDateFormatter.string(from: referenceDate(for: meta))
        return """
        ---
        date: \(dateLabel)
        duration: \(durationLabel(durationMs: meta.durationMs))
        source: kikimi
        session_id: \(meta.id)
        tags: \(frontmatterTags)
        ---
        """
    }

    // MARK: - Wall-clock conversion

    /// Converts a segment's `startMs` (kikimi.md 5/6 章's cumulative "recording active time"
    /// timeline) back to a real wall-clock `Date`, using whichever `RecordingSegment` in `recordings`
    /// owns that point on the timeline: the one with the greatest `startMsOffset <= startMs`
    /// (`recordings` is always `startMsOffset`-ascending, kikimi.md 5 章, so `last(where:)` -- which
    /// scans back-to-front and returns the first/highest-offset match -- resolves this correctly).
    /// Falls back to `fallback + startMs` if `recordings` is empty (defensive only; every session
    /// that has ever recorded has at least one segment by the time export/copy runs).
    static func wallClockDate(startMs: Int, recordings: [RecordingSegment], fallback: Date) -> Date {
        guard let owner = recordings.last(where: { $0.startMsOffset <= startMs }) ?? recordings.first else {
            return fallback.addingTimeInterval(Double(startMs) / 1_000)
        }
        let elapsedInSegment = Double(startMs - owner.startMsOffset) / 1_000
        return owner.startedAt.addingTimeInterval(elapsedInSegment)
    }

    /// `meta.startedAt` (first recording start) if present, else `meta.createdAt` -- shared by
    /// `wallClockDate(...)`'s fallback and the frontmatter/filename `date:` reference point, so both
    /// always agree even for a degenerate session with no `recordings` at all.
    ///
    /// `internal` (not `private`) so `WikiExportRenderer.fileName(for:)` can reuse the exact same
    /// reference point for the filename's date component (design §3.1).
    static func referenceDate(for meta: SessionMeta) -> Date {
        meta.startedAt ?? meta.createdAt
    }

    // MARK: - Duration label

    /// `meta.durationMs` as a whole-minute label (kikimi.md 11 章's sample: `2_722_000`ms ->
    /// `"45m"`). Rounds to the nearest minute rather than truncating.
    static func durationLabel(durationMs: Int) -> String {
        let minutes = Int((Double(durationMs) / 60_000).rounded())
        return "\(minutes)m"
    }

    // MARK: - Formatters

    /// `internal` (not `private`) so `WikiExportRenderer.fileName(for:)` can format the same
    /// `date:`-shaped string for the filename (design §3.1).
    static let frontmatterDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
