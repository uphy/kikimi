import SwiftUI

// MARK: - GlossaryBucket

/// Which slice of `glossary` the 用語集 tab is currently showing (`docs/design/28-glossary.md` §4).
///
/// `.all` is a pseudo-bucket: it spans every category so a term can be found without knowing where it
/// was filed. It is browse-only -- "+ 用語を追加" hides there, because a new entry would have no
/// unambiguous category to land in.
enum GlossaryBucket: Hashable {
    case all
    case uncategorized
    case category(id: String)

    /// The category a new entry added while viewing this bucket belongs to. `nil` for `.uncategorized`
    /// (which is exactly how an uncategorized entry is stored) and, defensively, for `.all` -- though
    /// the UI never offers the add button there.
    var categoryIdForNewEntries: String? {
        if case let .category(id) = self { return id }
        return nil
    }
}

// MARK: - GlossarySettingsTab

/// The "用語集" Settings tab (`docs/design/28-glossary.md` §4): the glossary shared by dictation
/// refinement and meeting-transcript refinement, edited as a category sidebar plus a detail pane.
///
/// It gets a whole tab rather than a section inside "一般" (where it originally lived, alongside
/// `stt`/`diarization`/`summary`/...) because it is the only *unbounded* list on that tab: once a
/// handful of terms were registered, every fixed setting below it -- 話者分離 onward -- was pushed off
/// the bottom of the window. Sharing its home with the "話者" tab's voiceprint list is the right
/// analogy: both are data-management tabs, not settings tabs.
///
/// **Why master-detail rather than a `category` picker on each row.** A per-row picker would make the
/// user choose a category on every single term, and would interleave the categories in one flat list.
/// Selecting a category first means "+ 用語を追加" already knows where the term goes, and a category's
/// terms are always seen together -- which is also how they are rendered into the prompt.
///
/// This type owns only what spans both panes: the selection, and category create/delete (deleting a
/// category never deletes its terms -- they fall back to 未分類).
struct GlossarySettingsTab: View {
    @ObservedObject private var appConfig = AppConfig.shared

    /// Opens on `.all`, which is the closest match to the flat list this tab used to be.
    @State private var selection: GlossaryBucket = .all

    /// Non-nil while the delete-category confirmation is up. Holds the id rather than a `Bool` so the
    /// alert's message can name the category and count its terms.
    @State private var pendingDeleteCategoryId: String?

    /// Set by `addCategory()`; makes the detail pane focus the new category's name field so it can be
    /// renamed immediately instead of being left as "新しいカテゴリ".
    @State private var categoryPendingRename: String?

    var body: some View {
        HStack(spacing: 0) {
            GlossaryCategorySidebar(
                selection: $selection,
                onAddCategory: addCategory,
                onDeleteCategory: { pendingDeleteCategoryId = $0 }
            )
            .frame(width: 160)

            Divider()

            GlossaryCategoryDetailView(
                selection: selection,
                categoryPendingRename: $categoryPendingRename
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .alert(
            "カテゴリを削除しますか？",
            isPresented: Binding(
                get: { pendingDeleteCategoryId != nil },
                set: { if !$0 { pendingDeleteCategoryId = nil } }
            )
        ) {
            Button("削除", role: .destructive) {
                if let id = pendingDeleteCategoryId { deleteCategory(id) }
                pendingDeleteCategoryId = nil
            }
            Button("キャンセル", role: .cancel) { pendingDeleteCategoryId = nil }
        } message: {
            Text(deleteConfirmationMessage)
        }
    }

    // MARK: Category CRUD

    /// Mints a UUID `id` -- never one derived from `name` -- so the user can rename the category
    /// afterwards without orphaning the entries that reference it (`GlossaryCategory`'s doc comment).
    private func addCategory() {
        let category = GlossaryCategory(id: UUID().uuidString, name: "新しいカテゴリ")
        appConfig.update { $0.glossaryCategories.append(category) }
        selection = .category(id: category.id)
        categoryPendingRename = category.id
    }

    /// Reassigns the category's entries to 未分類 *before* removing it, so no term is ever lost to a
    /// category deletion. (Entries would resolve to 未分類 anyway once the id dangles -- see
    /// `GlossaryCategorization` -- but leaving a dead id on disk would resurrect them into any
    /// future category that happened to reuse the id.)
    private func deleteCategory(_ id: String) {
        appConfig.update { config in
            for index in config.glossary.indices where config.glossary[index].category == id {
                config.glossary[index].category = nil
            }
            config.glossaryCategories.removeAll { $0.id == id }
        }
        selection = .uncategorized
    }

    private var deleteConfirmationMessage: String {
        guard let id = pendingDeleteCategoryId,
              let category = appConfig.data.glossaryCategories.first(where: { $0.id == id })
        else { return "" }
        let count = GlossaryCategorization.indices(entries: appConfig.data.glossary, in: id).count
        guard count > 0 else { return "「\(category.name)」を削除します。" }
        return "「\(category.name)」に登録されている \(count) 件の用語は削除されず、未分類に移動します。"
    }
}
