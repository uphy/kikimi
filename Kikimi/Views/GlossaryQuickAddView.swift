import SwiftUI

// MARK: - GlossaryQuickAddView

/// The メニューバー "用語を登録…" quick-add form (`WindowManager.showGlossaryQuickAdd()`): a small,
/// single-purpose alternative to opening the full 用語集 Settings tab
/// (`GlossaryCategoryDetailView`) just to add one term while in a meeting or another app.
///
/// Shares the same `category` convention every other 用語集 UI relies on --
/// `GlossaryEntry.category` references a `GlossaryCategory.id`, and `nil` means "未分類"
/// (`GlossaryEntryRow`'s "カテゴリを移動" context menu, `GlossaryCategorization`) -- so an entry
/// created here shows up in exactly the same place the Settings tab would put it.
///
/// Input normalization (trim, blank-term rejection, category passthrough) lives in
/// `GlossaryQuickAdd.makeEntry(term:reading:categoryId:)`, not here, so it is unit-testable without
/// SwiftUI (`KikimiTests/Glossary/GlossaryQuickAddTests.swift`).
///
/// This view is hosted directly as a window's root content (`GlossaryQuickAddWindowController`), not
/// presented as a `.sheet` -- there is no `\.dismiss` environment action to fall back on, hence the
/// explicit `onDismiss` closure the controller wires to `window?.close()`. Both "キャンセル"/Esc and a
/// successful "登録" call it: `docs/design/28-glossary.md`'s existing forms don't offer a
/// "stay open, keep adding" mode, and keeping this one to a single close-on-save behavior avoids
/// inventing a new pattern.
struct GlossaryQuickAddView: View {
    @ObservedObject private var appConfig = AppConfig.shared

    /// Closes the hosting window. Called by "キャンセル", Esc (via the button's `.cancelAction`
    /// keyboard shortcut), and by `save()` on success.
    let onDismiss: () -> Void

    @State private var term = ""
    @State private var reading = ""
    /// `nil` selects "未分類" -- see `GlossaryEntry.category`'s doc comment.
    @State private var categoryId: String?

    /// Focused as soon as the form appears (`.onAppear` below), so the window opens ready to type
    /// the term straight away. `GlossaryQuickAddWindowController.show()` rebuilds this view fresh on
    /// every call, so re-showing an already-open window re-triggers `.onAppear` too.
    @FocusState private var isTermFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("用語を登録")
                .font(.headline)

            Form {
                Picker("カテゴリ", selection: $categoryId) {
                    Text("未分類").tag(String?.none)
                    ForEach(appConfig.data.glossaryCategories) { category in
                        Text(category.name).tag(String?.some(category.id))
                    }
                }

                TextField("用語（正しい表記）", text: $term)
                    .focused($isTermFocused)

                TextField("読み・置換元（任意）", text: $reading)
            }
            .formStyle(.grouped)
            // The grouped form is backed by a scroll view; with the fixed window height below all
            // three rows fit, so scrolling would only ever show a stray scrollbar.
            .scrollDisabled(true)

            HStack {
                Spacer()
                Button("キャンセル", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
                Button("登録", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding()
        .frame(width: 380, height: 240)
        .onAppear { isTermFocused = true }
    }

    private var isValid: Bool {
        GlossaryQuickAdd.makeEntry(term: term, reading: reading, categoryId: categoryId) != nil
    }

    private func save() {
        guard let entry = GlossaryQuickAdd.makeEntry(term: term, reading: reading, categoryId: categoryId) else {
            return
        }
        appConfig.update { $0.glossary.append(entry) }
        onDismiss()
    }
}
