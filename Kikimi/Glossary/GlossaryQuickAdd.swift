import Foundation

// MARK: - GlossaryQuickAdd

/// Pure input normalization for the メニューバー "用語を登録…" quick-add form
/// (`GlossaryQuickAddView`, `WindowManager.showGlossaryQuickAdd()`). Factored out of the view so the
/// "trim / reject a blank term / pass the category through untouched" rule is unit-testable without
/// SwiftUI, matching how `GlossaryCategorization`/`GlossaryFilter`/`GlossaryReorder` each carry their
/// own pure core next to the views that use them.
enum GlossaryQuickAdd {
    /// Builds a `GlossaryEntry` from raw quick-add form input, or `nil` when the term is blank once
    /// trimmed -- the term is the one required field (`docs/design/28-glossary.md` §2), same rule
    /// `GlossaryCategoryDetailView`'s "+ 用語を追加" leaves for the user to fill in inline; here there
    /// is no inline row to leave blank, so an empty term instead disables "登録" entirely.
    ///
    /// `reading` is trimmed but never required (`GlossaryEntry.reading`'s own doc comment: empty
    /// means "nothing to replace, list the term bare"). `categoryId` is passed through as-is --
    /// `nil` already means "uncategorized" on `GlossaryEntry.category`, exactly what the "未分類"
    /// Picker option is expected to supply as its selection tag, so there is nothing left to resolve.
    static func makeEntry(term: String, reading: String, categoryId: String?) -> GlossaryEntry? {
        let trimmedTerm = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTerm.isEmpty else { return nil }
        return GlossaryEntry(
            term: trimmedTerm,
            reading: reading.trimmingCharacters(in: .whitespacesAndNewlines),
            category: categoryId
        )
    }
}
