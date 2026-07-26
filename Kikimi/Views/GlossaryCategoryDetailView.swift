import SwiftUI

// MARK: - GlossaryCategoryDetailView

/// The 用語集 tab's right pane (`docs/design/28-glossary.md` §4): the selected bucket's header (an
/// editable name + instruction for a real category), a 絞り込み field, the term list, and
/// "+ 用語を追加".
///
/// The list gets the pane's full remaining height and scrolls inside it, so "+ 用語を追加" stays pinned
/// at the bottom no matter how many terms exist.
struct GlossaryCategoryDetailView: View {
    @ObservedObject private var appConfig = AppConfig.shared

    let selection: GlossaryBucket
    /// Set by `GlossarySettingsTab.addCategory()`; focuses the name field of a just-created category so
    /// it can be renamed straight away rather than left as "新しいカテゴリ". Cleared once consumed.
    @Binding var categoryPendingRename: String?

    @State private var searchQuery = ""

    /// Focuses the term field of a freshly added entry, so "+ 用語を追加" leaves the caret where the
    /// user is about to type instead of merely appending a blank row somewhere below the fold.
    @FocusState private var focusedTermIndex: Int?
    @FocusState private var isCategoryNameFocused: Bool

    /// Set by `addEntry()` in the same state transaction that appends the entry; consumed (and cleared)
    /// by the list's `onChange`, which by then is running against a view tree that contains the new row.
    @State private var pendingScrollTarget: Int?

    /// Which reorder drop separator (`docs/design/28-glossary.md` §4.3), if any, an in-flight drag is
    /// currently over. `gapIndex` is the position in `0...bucketIndices.count` the separator represents
    /// ("insert before bucket position `gapIndex`") -- see `reorderSeparator(at:)`.
    @State private var targetedGapIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            toolbar
            entryList
            if selection != .all {
                Button("+ 用語を追加", action: addEntry)
            }
        }
        .padding()
        // Switching buckets with a query still applied looks like an empty category. Clear it instead.
        .onChange(of: selection) { _, _ in
            searchQuery = ""
            focusedTermIndex = nil
        }
        .onChange(of: categoryPendingRename) { _, pending in
            guard pending != nil else { return }
            isCategoryNameFocused = true
            categoryPendingRename = nil
        }
    }

    // MARK: Model access

    private var entries: [GlossaryEntry] { appConfig.data.glossary }
    private var categories: [GlossaryCategory] { appConfig.data.glossaryCategories }

    private var selectedCategory: GlossaryCategory? {
        guard case let .category(id) = selection else { return nil }
        return categories.first { $0.id == id }
    }

    /// Indices of every entry in the selected bucket, ignoring the 絞り込み query -- ascending, as
    /// required by `GlossaryReorder.reordered(entries:bucketIndices:from:to:)`. Reordering (drag or the
    /// "上へ/下へ移動" fallback) always permutes this exact set, never the narrower `visibleIndices`.
    private var bucketIndices: [Int] {
        switch selection {
        case .all:
            Array(entries.indices)
        case .uncategorized:
            GlossaryCategorization.uncategorizedIndices(entries: entries, categories: categories)
        case let .category(id):
            GlossaryCategorization.indices(entries: entries, in: id)
        }
    }

    /// Indices of the entries in the selected bucket, narrowed by the 絞り込み query. Composed from
    /// `bucketIndices` intersected with the query match (`GlossaryFilter`), re-sorted back into the
    /// original array's order, which the rows' identity depends on.
    private var visibleIndices: [Int] {
        guard !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return bucketIndices }
        let matching = Set(GlossaryFilter.matchingIndices(in: entries, query: searchQuery))
        return bucketIndices.filter { matching.contains($0) }
    }

    /// Every entry in the selected bucket, ignoring the query -- the denominator of the count label.
    private var bucketCount: Int { bucketIndices.count }

    /// Reordering needs an unambiguous "insert here" position among the bucket's *entire* membership.
    /// While a 絞り込み query hides part of the bucket, "drop before this visible row" no longer says
    /// where among the hidden members the entry should land, so both the drag separators and the
    /// "上へ/下へ移動" context-menu fallback are suppressed (`docs/design/28-glossary.md` §4.3). Dragging
    /// onto the sidebar (re-categorizing, not reordering) is unaffected -- that destination stays
    /// unambiguous regardless of filtering.
    private var isFilteringActive: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Header

    @ViewBuilder
    private var header: some View {
        switch selection {
        case .all:
            titleAndCaption(
                "すべて",
                "すべてのカテゴリの用語を表示しています。用語を追加するにはカテゴリを選んでください。"
            )
        case .uncategorized:
            titleAndCaption(
                "未分類",
                "カテゴリに属さない用語です。音声認識が誤変換しやすい固有名詞・専門用語を登録すると、"
                    + "会議書き起こしとディクテーションの整形時に元の用語へ置換されやすくなります。"
            )
        case .category:
            categoryHeader
        }
    }

    private func titleAndCaption(_ title: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// A category's name and instruction are edited in place, live-bound to `config.yaml` like every
    /// other field in Settings. Renaming only ever touches `glossaryCategories[i].name` -- entries
    /// reference the immutable `id`, so none of them move.
    @ViewBuilder
    private var categoryHeader: some View {
        if let category = selectedCategory {
            VStack(alignment: .leading, spacing: 6) {
                TextField("カテゴリ名", text: categoryNameBinding(id: category.id))
                    .textFieldStyle(.roundedBorder)
                    .font(.headline)
                    .focused($isCategoryNameFocused)

                Text("このカテゴリの用語をプロンプトに渡すときの追加指示（任意）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: categoryInstructionBinding(id: category.id))
                    .font(.body.monospaced())
                    .frame(height: 56)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            }
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                TextField("絞り込み", text: $searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                Spacer()
                Text(countLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // Reordering needs the bucket's full membership, which a query hides part of -- see
            // `isFilteringActive`'s doc comment.
            if isFilteringActive {
                Text("絞り込み中は並び替えできません")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// "12 件登録済み" normally; "3 / 12 件" while a 絞り込み query is narrowing the list, so the hidden
    /// entries never read as deleted ones.
    private var countLabel: String {
        let total = bucketCount
        let visible = visibleIndices.count
        return visible == total ? "\(total) 件登録済み" : "\(visible) / \(total) 件"
    }

    // MARK: List

    /// Always claims the pane's full remaining height (`maxHeight: .infinity`), empty states included,
    /// so "+ 用語を追加" never drifts up the window as entries are added or filtered away.
    @ViewBuilder
    private var entryList: some View {
        Group {
            if bucketCount == 0 {
                placeholder("登録済みの用語はありません。")
            } else if visibleIndices.isEmpty {
                placeholder("「\(searchQuery)」に一致する用語はありません。")
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    columnHeaders
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 4) {
                                // Keyed by the *original* index, not the position within `visibleIndices`:
                                // otherwise filtering (or switching buckets) would hand a row's identity,
                                // and the keyboard focus riding on it, to whichever entry slid into that
                                // slot. Doubly important now that the visible set is bucket ∩ query.
                                //
                                // While not filtering, `visibleIndices` is exactly `bucketIndices` in the
                                // same order, so `position` (the `enumerated()` offset) doubles as the
                                // row's position within the bucket -- reused below both for the "insert
                                // here" separators and for `reorderContext`'s up/down bounds. A thin
                                // `Color.clear` separator (fixed *height*, unconstrained width) is safe
                                // here; the documented trap is the opposite -- a `Color.clear` constrained
                                // only in *width* still expands to fill all available height.
                                if !isFilteringActive {
                                    reorderSeparator(at: 0)
                                }
                                ForEach(Array(visibleIndices.enumerated()), id: \.element) { position, index in
                                    GlossaryEntryRow(
                                        index: index,
                                        showsCategoryLabel: selection == .all,
                                        focusedTermIndex: $focusedTermIndex,
                                        reorderContext: isFilteringActive ? nil : reorderContext(atBucketPosition: position)
                                    )
                                    .id(index)
                                    if !isFilteringActive {
                                        reorderSeparator(at: position + 1)
                                    }
                                }
                            }
                            .padding(.trailing, 2)
                        }
                        // Follows "+ 用語を追加" down to the row it just appended, which is otherwise below
                        // the fold whenever the list is scrolled anywhere but the bottom. Keyed off
                        // `pendingScrollTarget` rather than off `focusedTermIndex`, for two reasons: the
                        // appended row does not exist in the view tree until SwiftUI has rebuilt the list,
                        // so focus (and any scroll chasing it) has nothing to land on yet; and scrolling on
                        // every focus change would also yank the list around whenever the user merely
                        // clicks into an existing row.
                        .onChange(of: pendingScrollTarget) { _, target in
                            guard let target else { return }
                            proxy.scrollTo(target, anchor: .bottom)
                            focusedTermIndex = target
                            pendingScrollTarget = nil
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func placeholder(_ message: String) -> some View {
        VStack {
            Spacer()
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var columnHeaders: some View {
        HStack(spacing: 8) {
            Text("用語（正しい表記）")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("読み・置換元（任意）")
                .frame(maxWidth: .infinity, alignment: .leading)
            // Reserves exactly the trailing delete button's width so the two column titles line up
            // with the two text fields below them. `Spacer`, not `Color.clear`: a `Color` constrained
            // only in width still expands to fill the available *height*, which stretches this header
            // row down over the list.
            Spacer().frame(width: 20)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: Reordering (drag and "上へ/下へ移動")

    /// A thin "insert here" drop target between (and around) rows, representing bucket position
    /// `gapIndex` in `0...bucketIndices.count` -- `gapIndex == 0` is "before the first row",
    /// `gapIndex == bucketIndices.count` is "after the last row". Its `to:` value is handed straight to
    /// `GlossaryReorder.reordered(entries:bucketIndices:from:to:)`, whose destination convention is
    /// defined to make exactly this "insert before this gap" meaning require no further adjustment.
    ///
    /// Only ever installed while `!isFilteringActive` (see the call sites in `entryList`); the caller is
    /// responsible for that, so this function does not re-check it.
    @ViewBuilder
    private func reorderSeparator(at gapIndex: Int) -> some View {
        Color.clear
            .frame(height: 6)
            .background(targetedGapIndex == gapIndex ? Color.accentColor.opacity(0.3) : Color.clear)
            .dropDestination(for: GlossaryEntryTransfer.self) { items, _ in
                guard let transfer = items.first else { return false }
                return handleReorderDrop(transfer, to: gapIndex)
            } isTargeted: { targeted in
                targetedGapIndex = targeted ? gapIndex : (targetedGapIndex == gapIndex ? nil : targetedGapIndex)
            }
    }

    /// Revalidates the drag payload (bounds, term, *and* current bucket membership -- a drag can outlive
    /// a bucket switch or a concurrent edit that moved the entry to a different category) before
    /// mutating. A stale or now-foreign drop is silently ignored.
    private func handleReorderDrop(_ transfer: GlossaryEntryTransfer, to gapIndex: Int) -> Bool {
        let currentBucketIndices = bucketIndices
        guard entries.indices.contains(transfer.index),
              entries[transfer.index].term == transfer.term,
              let from = currentBucketIndices.firstIndex(of: transfer.index)
        else { return false }
        let reorderedEntries = GlossaryReorder.reordered(
            entries: entries,
            bucketIndices: currentBucketIndices,
            from: from,
            to: gapIndex
        )
        appConfig.update { $0.glossary = reorderedEntries }
        return true
    }

    /// The "上へ/下へ移動" context-menu fallback for the row at bucket position `position`
    /// (`docs/design/28-glossary.md` §4.3). `+1`/`-1` neighbor swaps are expressed in
    /// `GlossaryReorder`'s `to:` convention as `position - 1` (up) / `position + 2` (down) -- see that
    /// type's doc comment for why `+ 1` would be a no-op.
    private func reorderContext(atBucketPosition position: Int) -> GlossaryEntryReorderContext {
        let bucketSize = bucketIndices.count
        return GlossaryEntryReorderContext(
            canMoveUp: position > 0,
            canMoveDown: position < bucketSize - 1,
            moveUp: { moveEntry(atBucketPosition: position, to: position - 1) },
            moveDown: { moveEntry(atBucketPosition: position, to: position + 2) }
        )
    }

    private func moveEntry(atBucketPosition position: Int, to destination: Int) {
        let reorderedEntries = GlossaryReorder.reordered(
            entries: entries,
            bucketIndices: bucketIndices,
            from: position,
            to: destination
        )
        appConfig.update { $0.glossary = reorderedEntries }
    }

    // MARK: Actions

    /// Clears any 絞り込み query first: a blank entry matches no query, so adding one while the list is
    /// filtered would otherwise append a row the user cannot see. Scrolling to the new row and focusing
    /// it is left to the list's `onChange(of: pendingScrollTarget)`, which runs once the row exists.
    private func addEntry() {
        searchQuery = ""
        let category = selection.categoryIdForNewEntries
        appConfig.update { $0.glossary.append(GlossaryEntry(term: "", reading: "", category: category)) }
        pendingScrollTarget = entries.count - 1
    }

    private func categoryNameBinding(id: String) -> Binding<String> {
        Binding(
            get: { categories.first { $0.id == id }?.name ?? "" },
            set: { newValue in
                appConfig.update { config in
                    guard let index = config.glossaryCategories.firstIndex(where: { $0.id == id }) else { return }
                    config.glossaryCategories[index].name = newValue
                }
            }
        )
    }

    private func categoryInstructionBinding(id: String) -> Binding<String> {
        Binding(
            get: { categories.first { $0.id == id }?.instruction ?? "" },
            set: { newValue in
                appConfig.update { config in
                    guard let index = config.glossaryCategories.firstIndex(where: { $0.id == id }) else { return }
                    config.glossaryCategories[index].instruction = newValue
                }
            }
        )
    }
}
