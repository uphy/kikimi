import AppKit
import SwiftUI

// MARK: - DictationOverlayState

/// `@Published` backing for `DictationOverlayView`, kept separate from `DictationOverlayPanelController`
/// so `show(text:method:)` can update the panel's content without tearing down and rebuilding the
/// `NSHostingView` (mirrors why `SettingsWindowController` builds its `SettingsView` once in `init`).
@MainActor
private final class DictationOverlayState: ObservableObject {
    @Published var text: String = ""
    var method: DictationInsertMethod = .pasteboard
}

// MARK: - DictationOverlayView

/// The panel's content (`docs/design/25-dictation-mode.md` §3.6): the stashed text plus
/// `[挿入]`/`[コピー]`/`[閉じる]`.
private struct DictationOverlayView: View {
    @ObservedObject fileprivate var state: DictationOverlayState
    let onInsert: () -> Void
    let onCopy: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("挿入先が変わったため、挿入を保留しています")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                Text(state.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 120)
            HStack {
                Button("挿入", action: onInsert)
                    .help("今のフォーカス先へ挿入")
                Button("コピー", action: onCopy)
                    .help("クリップボードにコピー")
                Spacer()
                Button("閉じる", action: onClose)
                    .help("このパネルを閉じる")
            }
        }
        .padding()
        .frame(width: 320)
    }
}

// MARK: - DictationOverlayPanelController

/// The D2 misfire-guard stash destination (`docs/design/25-dictation-mode.md` R5/§3.6/§8),
/// replacing D1's silent clipboard-only stash now that refinement's ~1s round trip raises the
/// misfire probability enough to justify a panel. Built on the shared `FloatingPanel` base
/// (`Kikimi/Window/FloatingPanel.swift`).
///
/// A single long-lived instance owned by `DictationController`, reused across every abort (mirrors
/// `SettingsWindowController`'s singleton-per-window-kind lifecycle) -- aborts happen one utterance
/// at a time, never concurrently, so there is never a need for more than one panel.
@MainActor
final class DictationOverlayPanelController: NSWindowController {
    private static let size = CGSize(width: 320, height: 160)

    private let inserter: any DictationInserting
    private let state = DictationOverlayState()

    init(inserter: any DictationInserting) {
        self.inserter = inserter
        let panel = FloatingPanel(contentRect: CGRect(origin: .zero, size: Self.size))
        panel.title = "ディクテーション"
        panel.isMovableByWindowBackground = true
        panel.isRestorable = false

        super.init(window: panel)

        panel.contentView = FirstMouseHostingView(rootView: DictationOverlayView(
            state: state,
            onInsert: { [weak self] in self?.handleInsert() },
            onCopy: { [weak self] in self?.handleCopy() },
            onClose: { [weak self] in self?.handleClose() }
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Shows the panel with `text` staged for `[挿入]`/`[コピー]`. Never activates the app or
    /// steals key focus (`window?.orderFront(nil)`, not `makeKeyAndOrderFront`/`NSApp.activate`) --
    /// `FloatingPanel`'s whole point is staying out of the way of whatever app the user is in.
    func show(text: String, method: DictationInsertMethod) {
        state.text = text
        state.method = method
        window?.center()
        if !HiddenTestMode.isActive {
            window?.orderFront(nil)
        }
    }

    /// `DictationInserter.performInsert(_:method:)`: no `FrontmostGuard` re-check (R5/§8's "再度の
    /// 検証は挟まない -- ユーザーが明示的に押した瞬間の frontmost を意図とみなす").
    private func handleInsert() {
        inserter.performInsert(state.text, method: state.method)
        window?.orderOut(nil)
    }

    private func handleCopy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(state.text, forType: .string)
        window?.orderOut(nil)
    }

    private func handleClose() {
        window?.orderOut(nil)
    }
}
