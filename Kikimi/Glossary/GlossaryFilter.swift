import Foundation

// MARK: - GlossaryFilter

/// The "絞り込み" search backing `GlossarySettingsTab` (`docs/design/28-glossary.md` §4).
///
/// Returns *indices into the original array* rather than filtered `GlossaryEntry` values, because the
/// tab edits entries in place through `AppConfig.update { $0.glossary[index]... }` -- a filtered copy
/// would have no way back to the entry it came from.
enum GlossaryFilter {
    /// Indices of the entries whose `term` or `reading` contains `query`, in original array order.
    /// An empty (or whitespace-only) query matches everything.
    ///
    /// Matching is `localizedStandardContains`, so it is case- and diacritic-insensitive the way the
    /// rest of macOS's search fields are -- `"ai"` finds `"Acme Works"`.
    static func matchingIndices(in entries: [GlossaryEntry], query: String) -> [Int] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Array(entries.indices) }
        return entries.indices.filter { index in
            let entry = entries[index]
            return entry.term.localizedStandardContains(trimmed)
                || entry.reading.localizedStandardContains(trimmed)
        }
    }
}
