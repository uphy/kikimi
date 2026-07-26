import SwiftUI

// MARK: - GlossaryCategorySidebar

/// The 用語集 tab's left pane (`docs/design/28-glossary.md` §4): すべて / 未分類 / one row per
/// `glossary_categories` entry, each with its term count, above `[+]`/`[−]` category buttons.
///
/// Counts come from `GlossaryCategorization`, the same grouping used to render the prompt, so a term
/// can never be counted in a category the prompt files it under differently (notably: an entry whose
/// `category` id no longer exists counts under 未分類 in both).
///
/// 未分類 and each category row also accept a drop of `GlossaryEntryTransfer` (§4.3) to re-categorize the
/// dragged entry -- a drag-and-drop sibling to the row's own "カテゴリを移動" context menu, which stays as
/// a redundant, no-drag path. **すべて deliberately accepts no drop**: it spans every category, so there
/// is no single destination a drop onto it could mean, and it must not even highlight to suggest one.
struct GlossaryCategorySidebar: View {
    @ObservedObject private var appConfig = AppConfig.shared

    @Binding var selection: GlossaryBucket
    let onAddCategory: () -> Void
    /// Called with the selected category's id. The confirmation alert -- and the reassignment of its
    /// terms to 未分類 -- belong to `GlossarySettingsTab`, which owns both panes' state.
    let onDeleteCategory: (String) -> Void

    /// Which row, if any, an in-flight drag is currently over -- drives the drop highlight. A single
    /// piece of state (rather than one `@State` per row) because every row is produced by the shared
    /// `row(for:name:count:dropAssignment:)` helper, not by its own view struct.
    @State private var targetedBucket: GlossaryBucket?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: $selection) {
                row(for: .all, name: "すべて", count: appConfig.data.glossary.count)
                row(for: .uncategorized, name: "未分類", count: uncategorizedCount, dropAssignment: .uncategorized)

                if !appConfig.data.glossaryCategories.isEmpty {
                    Section("カテゴリ") {
                        ForEach(appConfig.data.glossaryCategories) { category in
                            row(
                                for: .category(id: category.id),
                                name: category.name,
                                count: GlossaryCategorization.indices(entries: appConfig.data.glossary, in: category.id).count,
                                dropAssignment: .category(category.id)
                            )
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            categoryButtons
        }
    }

    /// The category a successful drop assigns to the dragged entry. A dedicated enum (rather than a
    /// bare `String?`) so "未分類" and "no drop target at all" (すべて) are distinct cases instead of both
    /// being spelled with `nil` in different ways.
    private enum DropAssignment {
        case uncategorized
        case category(String)

        var categoryId: String? {
            switch self {
            case .uncategorized: nil
            case let .category(id): id
            }
        }
    }

    /// `List(selection:)` on macOS only tracks a row's `tag`, so every row carries its bucket. The tap
    /// gesture is a belt-and-braces fallback: rows inside a `Section` occasionally miss selection when
    /// the list is not the window's first responder.
    ///
    /// `dropAssignment` is `nil` for すべて, which installs no `.dropDestination` at all and therefore
    /// never highlights.
    private func row(for bucket: GlossaryBucket, name: String, count: Int, dropAssignment: DropAssignment? = nil) -> some View {
        let base = HStack {
            Text(name)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Text("\(count)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .tag(bucket)
        .contentShape(Rectangle())
        .onTapGesture { selection = bucket }
        .listRowBackground(targetedBucket == bucket ? Color.accentColor.opacity(0.15) : Color.clear)

        return Group {
            if let dropAssignment {
                base.dropDestination(for: GlossaryEntryTransfer.self) { items, _ in
                    guard let transfer = items.first else { return false }
                    return handleDrop(transfer, assignment: dropAssignment)
                } isTargeted: { targeted in
                    targetedBucket = targeted ? bucket : (targetedBucket == bucket ? nil : targetedBucket)
                }
            } else {
                base
            }
        }
    }

    /// Revalidates the drag payload (index still in bounds *and* still the same term -- see
    /// `GlossaryEntryTransfer`) before mutating; a stale or superseded drop is silently ignored rather
    /// than reassigning whatever entry now happens to occupy that index.
    private func handleDrop(_ transfer: GlossaryEntryTransfer, assignment: DropAssignment) -> Bool {
        let glossary = appConfig.data.glossary
        guard glossary.indices.contains(transfer.index), glossary[transfer.index].term == transfer.term else {
            return false
        }
        appConfig.update { config in
            guard config.glossary.indices.contains(transfer.index) else { return }
            config.glossary[transfer.index].category = assignment.categoryId
        }
        return true
    }

    private var uncategorizedCount: Int {
        GlossaryCategorization.uncategorizedIndices(
            entries: appConfig.data.glossary,
            categories: appConfig.data.glossaryCategories
        ).count
    }

    /// `[−]` is enabled only for a real category: すべて and 未分類 are structural, not user data.
    private var categoryButtons: some View {
        HStack(spacing: 4) {
            Button(action: onAddCategory) {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("カテゴリを追加")

            Button {
                if case let .category(id) = selection { onDeleteCategory(id) }
            } label: {
                Image(systemName: "minus")
            }
            .buttonStyle(.borderless)
            .disabled(!isCategorySelected)
            .help("選択中のカテゴリを削除（用語は未分類に移動します）")

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var isCategorySelected: Bool {
        if case .category = selection { return true }
        return false
    }
}
