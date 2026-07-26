import SwiftUI

// MARK: - GlossaryEntryReorderContext

/// Wires the "上へ移動" / "下へ移動" context-menu fallback into a row (`docs/design/28-glossary.md`
/// §4.3): a no-drag path to reorder within the current bucket, for when drag and drop is inconvenient.
///
/// `nil` at the call site (rather than an instance with both flags `false`) means "hide the menu items
/// entirely" -- while 絞り込み is active, a row's position within the *bucket* is ambiguous from what is
/// merely visible, so there is nothing sensible to move it relative to. When non-nil, `canMoveUp` /
/// `canMoveDown` instead *disable* the item at each end of the bucket, matching the drag affordance's own
/// behavior at the bucket's boundaries.
struct GlossaryEntryReorderContext {
    let canMoveUp: Bool
    let canMoveDown: Bool
    let moveUp: () -> Void
    let moveDown: () -> Void
}

// MARK: - GlossaryEntryRow

/// One glossary term (`docs/design/28-glossary.md` §4): a drag handle, the term, its optional
/// replacement source, and a delete button, plus "カテゴリを移動" / "上へ移動" / "下へ移動" context menu
/// items.
///
/// Addressed by its **index into `AppConfig.shared.data.glossary`**, not by value, because that is the
/// only handle the enclosing list has back to the entry it is editing in place (its visible rows are a
/// filtered subset of a bucket). Every read of that index is bounds-checked -- see `entry`.
struct GlossaryEntryRow: View {
    @ObservedObject private var appConfig = AppConfig.shared

    let index: Int
    /// Only the `.all` bucket needs to say which category a row belongs to; inside a category it would
    /// repeat the pane's own header on every line.
    let showsCategoryLabel: Bool
    var focusedTermIndex: FocusState<Int?>.Binding
    /// `nil` while 絞り込み is active -- see `GlossaryEntryReorderContext`.
    let reorderContext: GlossaryEntryReorderContext?

    var body: some View {
        HStack(spacing: 8) {
            dragHandle
            VStack(alignment: .leading, spacing: 2) {
                if showsCategoryLabel {
                    Text(categoryLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                TextField("用語（正しい表記）", text: termBinding)
                    .textFieldStyle(.roundedBorder)
                    .focused(focusedTermIndex, equals: index)
            }
            TextField("読み・置換元（任意）", text: readingBinding)
                .textFieldStyle(.roundedBorder)
            Button(role: .destructive) {
                appConfig.update {
                    guard $0.glossary.indices.contains(index) else { return }
                    $0.glossary.remove(at: index)
                }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .frame(width: 20)
            .help("この用語を削除")
        }
        .contextMenu {
            Menu("カテゴリを移動") {
                Button("未分類") { move(to: nil) }
                ForEach(appConfig.data.glossaryCategories) { category in
                    Button(category.name) { move(to: category.id) }
                }
            }
            if let reorderContext {
                Divider()
                Button("上へ移動", action: reorderContext.moveUp)
                    .disabled(!reorderContext.canMoveUp)
                Button("下へ移動", action: reorderContext.moveDown)
                    .disabled(!reorderContext.canMoveDown)
            }
        }
    }

    /// Leading drag handle (`docs/design/28-glossary.md` §4.3). **Only this icon is a drag source, not
    /// the whole row.** The row is almost entirely `TextField`s; making the full `HStack` draggable
    /// would make every click-and-drag inside a text field ambiguous between "place the caret / select
    /// text" and "drag the row", fighting normal text editing. Confining the drag gesture to a small,
    /// non-interactive icon removes that ambiguity entirely -- this is the entire reason the handle
    /// exists as a separate element rather than a `.draggable` on the row itself.
    ///
    /// No handle is offered once the row's own entry has fallen out of bounds (see `entry`) -- there is
    /// nothing left to drag.
    ///
    /// `WindowDragBlocker` is what makes the drag reach SwiftUI at all: the Settings panel is
    /// `isMovableByWindowBackground`, and a bare `Image` has no `NSView` to tell AppKit "do not drag the
    /// window from here", so mouse-down on the handle used to move the whole window instead of starting
    /// the drag. See that type's doc comment.
    @ViewBuilder
    private var dragHandle: some View {
        let icon = Image(systemName: "line.3.horizontal")
            .foregroundStyle(.secondary)
            .frame(width: 16)
            .contentShape(Rectangle())
            .background(WindowDragBlocker())
            .help("ドラッグしてカテゴリを移動 / 並び替え")
        if let entry {
            icon.draggable(GlossaryEntryTransfer(index: index, term: entry.term))
        } else {
            icon
        }
    }

    /// Resolved through `GlossaryCategorization`, so an entry pointing at a category that no longer
    /// exists reads as 未分類 here exactly as it does in the rendered prompt.
    private var categoryLabel: String {
        guard let entry else { return "未分類" }
        let knownIds = Set(appConfig.data.glossaryCategories.map(\.id))
        guard let id = GlossaryCategorization.resolvedCategoryId(of: entry, knownIds: knownIds),
              let category = appConfig.data.glossaryCategories.first(where: { $0.id == id })
        else { return "未分類" }
        return category.name
    }

    private func move(to categoryId: String?) {
        appConfig.update {
            guard $0.glossary.indices.contains(index) else { return }
            $0.glossary[index].category = categoryId
        }
    }

    private var termBinding: Binding<String> {
        Binding(
            get: { entry?.term ?? "" },
            set: { newValue in
                appConfig.update {
                    guard $0.glossary.indices.contains(index) else { return }
                    $0.glossary[index].term = newValue
                }
            }
        )
    }

    private var readingBinding: Binding<String> {
        Binding(
            get: { entry?.reading ?? "" },
            set: { newValue in
                appConfig.update {
                    guard $0.glossary.indices.contains(index) else { return }
                    $0.glossary[index].reading = newValue
                }
            }
        )
    }

    /// Bounds-checked: SwiftUI can evaluate a deleted row's bindings once more before it drops the row
    /// from the view tree, and `config.yaml`'s file watcher can shrink the array from under the list at
    /// any moment (`AppConfig`'s `watchForChanges: true`).
    private var entry: GlossaryEntry? {
        let glossary = appConfig.data.glossary
        return glossary.indices.contains(index) ? glossary[index] : nil
    }
}
