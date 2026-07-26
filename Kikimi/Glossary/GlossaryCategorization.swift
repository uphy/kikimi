import Foundation

// MARK: - GlossaryCategorization

/// Resolves `GlossaryEntry.category` into buckets (`docs/design/28-glossary.md` §1.2). Shared by
/// `GlossaryRenderer` and the 用語集 Settings tab so "dangling category id degrades to uncategorized"
/// is implemented exactly once, rather than as a decode-time repair *and* a render-time repair that
/// can drift apart.
///
/// Every function returns **indices into the original `entries` array**, in that array's own order --
/// not copies of the entries. The Settings UI edits entries in place through
/// `AppConfig.update { $0.glossary[index]... }`, so a filtered copy would have no way back to the entry
/// it came from (same reason `GlossaryFilter` returns indices).
///
/// Category ids are compared **after trimming whitespace** on the entry's side. Without that, an entry
/// carrying `category: " person "` would be counted as categorized by `uncategorizedIndices` (its
/// trimmed id is a known one) yet match no category in `indices(entries:in:)`, and would silently
/// vanish from both the prompt and the UI.
enum GlossaryCategorization {
    /// The entry's category id with surrounding whitespace removed, or `nil` when it is absent, blank,
    /// or names a category that does not exist in `knownIds`.
    static func resolvedCategoryId(of entry: GlossaryEntry, knownIds: Set<String>) -> String? {
        guard let trimmed = entry.category?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              knownIds.contains(trimmed)
        else { return nil }
        return trimmed
    }

    /// Indices of entries with no category, a blank one, or one that matches no `categories[].id`.
    static func uncategorizedIndices(entries: [GlossaryEntry], categories: [GlossaryCategory]) -> [Int] {
        let knownIds = Set(categories.map(\.id))
        return entries.indices.filter { resolvedCategoryId(of: entries[$0], knownIds: knownIds) == nil }
    }

    /// Indices of entries belonging to `categoryId`. Takes the id rather than the category list because
    /// the caller already knows the category exists -- an entry pointing at a *different*, unknown id
    /// simply doesn't match, and `uncategorizedIndices` is what picks it up.
    static func indices(entries: [GlossaryEntry], in categoryId: String) -> [Int] {
        entries.indices.filter { index in
            entries[index].category?.trimmingCharacters(in: .whitespacesAndNewlines) == categoryId
        }
    }
}
