import Foundation

// MARK: - WikiExportRenderer

/// Pure rendering logic for `docs/design/08-wiki-export.md` (kikimi.md 11 章). Every function here is
/// side-effect-free and takes plain, already-loaded values -- never `SessionHandle`/`AppConfig`
/// directly -- so every rule the design doc specifies (frontmatter shape, wall-clock conversion,
/// raw-fallback marker, empty-`refined_text` exclusion, title-slug generation) is unit-testable
/// without any actor/filesystem involvement. `WikiExporter` (same directory) owns the I/O side:
/// reading a session via `SessionHandle`, resolving `ExportConfig.targetDir`, and writing the file
/// this type renders.
enum WikiExportRenderer {
    /// Everything `render(_:)`/`fileName(for:)` need, gathered by `WikiExporter.export(sessionHandle:)`
    /// from `SessionHandle`'s already-existing read APIs.
    struct Input {
        var meta: SessionMeta
        /// `summary.md`'s already-rendered text (kikimi.md 11 章 "{summary.md の内容をそのまま埋め込み}"),
        /// or `""` if the session never got as far as a first summary update.
        var summaryMarkdown: String
        /// `sessionHandle.readRefinedSegments()`'s result, in whatever order it was read -- this type
        /// sorts by `startMs` itself (§4.3), so callers do not need to pre-sort.
        var refinedSegments: [RefinedSegment]
    }

    /// Marker appended to a transcript line whose `refinedText` was `nil` (refinement failure) and
    /// therefore fell back to `rawText` (kikimi.md 11 章 "フォールバックした行にはマーカーを付けて
    /// トレーサビリティを保つ", design §4.3).
    static let rawFallbackMarker = " *(raw)*"

    /// Fixed frontmatter `tags:` value (kikimi.md 11 章's sample; design §9 notes this is not
    /// currently configurable).
    private static let frontmatterTags = "[meeting, transcript]"

    private static let maxSlugLength = 80

    // MARK: - render

    /// Renders the full Markdown file body: frontmatter, `# title`, `## サマリ`, `## 書き起こし`
    /// (design §4), matching kikimi.md 11 章's sample shape. Always ends with exactly one trailing
    /// newline.
    static func render(_ input: Input) -> String {
        let meta = input.meta
        let referenceDate = self.referenceDate(for: meta)
        let dateLabel = frontmatterDateFormatter.string(from: referenceDate)

        var lines: [String] = []
        lines.append("---")
        lines.append("date: \(dateLabel)")
        lines.append("duration: \(durationLabel(durationMs: meta.durationMs))")
        lines.append("source: kikimi")
        lines.append("session_id: \(meta.id)")
        lines.append("tags: \(frontmatterTags)")
        lines.append("---")
        lines.append("")
        lines.append("# \(meta.title)")
        lines.append("")
        lines.append("## サマリ")
        lines.append("")
        lines.append(input.summaryMarkdown)
        lines.append("")
        lines.append("## 書き起こし")
        lines.append("")
        lines.append(contentsOf: transcriptLines(for: input, referenceDate: referenceDate))
        return lines.joined(separator: "\n") + "\n"
    }

    /// One `**HH:MM:SS (mic|system)** text` line per exported segment (design §4.3), blank-line
    /// separated, `startMs` ascending (ties broken by `id`). Segments `displayText(for:)` excludes
    /// (intentionally-deleted, `refined_text == ""`) produce no line at all.
    private static func transcriptLines(for input: Input, referenceDate: Date) -> [String] {
        let ordered = input.refinedSegments.sorted { lhs, rhs in
            lhs.startMs != rhs.startMs ? lhs.startMs < rhs.startMs : lhs.id < rhs.id
        }
        var lines: [String] = []
        for segment in ordered {
            guard let text = displayText(for: segment) else { continue }
            let wallClock = wallClockDate(startMs: segment.startMs, recordings: input.meta.recordings, fallback: referenceDate)
            let time = timeFormatter.string(from: wallClock)
            lines.append("**\(time) (\(segment.speaker.rawValue))** \(text)")
            lines.append("")
        }
        if lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines
    }

    /// Resolves one segment's exported transcript text (kikimi.md 11 章 / 7 章), or `nil` to exclude
    /// the line entirely:
    ///
    /// - `refinedText` non-nil and non-empty -> used as-is (the normal, successfully-refined case).
    /// - `refinedText == nil` (refinement failed, kikimi.md 5 章) -> falls back to `rawText`, with
    ///   `rawFallbackMarker` appended for traceability (design §4.3).
    /// - `refinedText == ""` (intentional deletion, kikimi.md 7 章 "意味なしと判定され削除された
    ///   セグメント") -> excluded entirely, never falls back to raw.
    static func displayText(for segment: RefinedSegment) -> String? {
        guard let refinedText = segment.refinedText else {
            return segment.rawText + rawFallbackMarker
        }
        guard !refinedText.isEmpty else {
            return nil
        }
        return refinedText
    }

    // MARK: - Wall-clock conversion

    /// Converts a segment's `startMs` (kikimi.md 5/6 章's cumulative "recording active time"
    /// timeline) back to a real wall-clock `Date`, using whichever `RecordingSegment` in `recordings`
    /// owns that point on the timeline: the one with the greatest `startMsOffset <= startMs`
    /// (`recordings` is always `startMsOffset`-ascending, kikimi.md 5 章, so `last(where:)` -- which
    /// scans back-to-front and returns the first/highest-offset match -- resolves this correctly).
    /// Falls back to `fallback + startMs` if `recordings` is empty (defensive only; every session
    /// that has ever recorded has at least one segment by the time export runs).
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
    private static func referenceDate(for meta: SessionMeta) -> Date {
        meta.startedAt ?? meta.createdAt
    }

    // MARK: - Duration label

    /// `meta.durationMs` as a whole-minute label (kikimi.md 11 章's sample: `2_722_000`ms ->
    /// `"45m"`). Rounds to the nearest minute rather than truncating.
    static func durationLabel(durationMs: Int) -> String {
        let minutes = Int((Double(durationMs) / 60_000).rounded())
        return "\(minutes)m"
    }

    // MARK: - Filename / slug

    /// `{date}-{slug}.md` (kikimi.md 11 章 "ファイル名は `YYYY-MM-DD-{タイトルslug}.md`"). The date
    /// component uses the same `referenceDate(for:)` as the frontmatter `date:` field, so the two
    /// always agree.
    static func fileName(for meta: SessionMeta) -> String {
        let dateLabel = frontmatterDateFormatter.string(from: referenceDate(for: meta))
        return "\(dateLabel)-\(slug(from: meta.title)).md"
    }

    /// Filesystem-safe slug for a (possibly Japanese, possibly empty, possibly symbol-laden) session
    /// title (design §4.4). Unlike a typical ASCII slugifier, this keeps non-ASCII characters --
    /// Japanese titles are the common case, and macOS/APFS filenames are UTF-8-safe -- and only
    /// replaces whitespace and characters that are unsafe/ambiguous in a filename or path
    /// (`/ \ : * ? " < > |`) with `-`. Runs of `-` are collapsed to one, leading/trailing `-` is
    /// trimmed, the result is truncated to `maxSlugLength` characters, and an empty result (blank
    /// title, or a title made entirely of unsafe characters) falls back to `"untitled"`.
    static func slug(from title: String) -> String {
        let unsafeCharacters = CharacterSet(charactersIn: "/\\:*?\"<>|")
        // Map first (whitespace/unsafe -> "-", everything else passes through unchanged), *then*
        // collapse consecutive "-" in a single uniform pass -- this also collapses hyphens that were
        // already literally present in the title (not just ones this function just introduced), so
        // e.g. an already-hyphenated title never produces a double hyphen either.
        let mapped: [Character] = title.unicodeScalars.map { scalar in
            if unsafeCharacters.contains(scalar) || CharacterSet.whitespacesAndNewlines.contains(scalar) {
                return "-"
            }
            return Character(scalar)
        }
        var collapsed = ""
        var lastWasHyphen = false
        for character in mapped {
            if character == "-" {
                if lastWasHyphen { continue }
                lastWasHyphen = true
            } else {
                lastWasHyphen = false
            }
            collapsed.append(character)
        }
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let truncated = String(trimmed.prefix(maxSlugLength))
        return truncated.isEmpty ? "untitled" : truncated
    }

    // MARK: - Formatters

    private static let frontmatterDateFormatter: DateFormatter = {
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
