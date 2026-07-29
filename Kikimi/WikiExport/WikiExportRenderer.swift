import Foundation

// MARK: - WikiExportRenderer

/// Export-file-name / slug generation only (kikimi.md 11 章 "ファイル名は
/// `YYYY-MM-DD-{タイトルslug}.md`", design §4.4). Body rendering (frontmatter, `# title`,
/// `## サマリ`, `## 書き起こし`) moved to `TranscriptMarkdownRenderer`
/// (`Kikimi/Markdown/TranscriptMarkdownRenderer.swift`, `docs/design/37-transcript-markdown-copy.md`
/// TC1) so that Wiki export and the "copy transcript as Markdown" feature share one renderer.
/// `WikiExporter` (same directory) builds a `TranscriptMarkdownRenderer.Input` and calls
/// `TranscriptMarkdownRenderer.render(_:scope:)` directly; this type is not a rendering entry point.
enum WikiExportRenderer {
    private static let maxSlugLength = 80

    // MARK: - Filename / slug

    /// `{date}-{slug}.md` (kikimi.md 11 章 "ファイル名は `YYYY-MM-DD-{タイトルslug}.md`"). The date
    /// component uses `TranscriptMarkdownRenderer.referenceDate(for:)` -- the same reference point
    /// `TranscriptMarkdownRenderer.render(_:scope:)` uses for the frontmatter `date:` field -- so the
    /// two always agree.
    static func fileName(for meta: SessionMeta) -> String {
        let dateLabel = TranscriptMarkdownRenderer.frontmatterDateFormatter.string(from: TranscriptMarkdownRenderer.referenceDate(for: meta))
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
}
