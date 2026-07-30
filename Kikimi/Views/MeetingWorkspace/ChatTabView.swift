import SwiftUI

// MARK: - ChatComposer

/// The composer's one decision, factored out of the view so it is unit-testable without
/// instantiating SwiftUI -- the same pattern `TranscriptAutoFollow`/`CopyFeedbackFlash` follow.
enum ChatComposer {
    /// Whitespace-only drafts are not sendable: they would cost an LLM call and produce an answer to
    /// nothing.
    static func canSend(draft: String, isResponding: Bool) -> Bool {
        !isResponding && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - ChatTabView

/// Session Window "チャット" tab (`docs/design/38-session-chat.md` §3.5): the conversation about this
/// session, newest at the bottom, with a multi-line composer beneath it.
///
/// A value-type view with no compile-time dependency on `MeetingWorkspaceViewModel` -- the same
/// contract `TranscriptTabView`/`WatchersTabView` keep.
///
/// The history itself is a web view (`ChatWebView`, `docs/design/39-webview-markdown.md` MD4): the
/// bubbles, the copy/retry buttons, the pending spinner and the auto-follow all live in
/// `web/src/chat.ts`, because one web view per answer would mean measuring and reporting each
/// bubble's height back into a SwiftUI list. What stays here is the toolbar and the composer --
/// `PlainTextEditor`'s IME handling is worth keeping.
struct ChatTabView: View {
    /// Already folded by `ChatTurnLog.fold(_:)`, oldest first.
    var turns: [ChatTurn]
    @Binding var draft: String
    /// While `true`, the composer is disabled and a spinner stands in for the pending answer.
    var isResponding: Bool
    /// `MeetingWorkspaceViewModel.chatCopyFeedbackTurnId` verbatim: the answer whose copy most
    /// recently succeeded. Driving the checkmark from this rather than from the tap itself is what
    /// makes a failed pasteboard write correctly show nothing (design 37 §6/TC11(f)).
    var copyFeedbackTurnId: String?
    var onSend: () -> Void
    /// Re-asks the question behind a failed answer; the argument is the **failed answer's** id.
    var onRetry: (String) -> Void
    var onCopy: (String) -> Void
    /// Discards the whole history. Invoked only after the confirmation below.
    var onClear: () -> Void
    /// Jumps to a transcript segment when an answer links one (`kikimi-seg:`). Wired through because
    /// the page routes every link the same way (design 39 MD6).
    var onOpenSegment: (String) -> Void = { _ in }
    /// The window-lifetime web view the history renders into (design 39 MD2).
    @ObservedObject var markdownHost: MarkdownWebViewHost

    /// When the in-flight answer was requested, for the page's "…秒" counter. `nil` when idle.
    @State private var respondingSince: Date?
    @State private var isConfirmingClear = false

    var body: some View {
        VStack(spacing: 0) {
            // Nothing to clear and nothing to say about an empty history, so the bar only appears
            // once there is one.
            if !turns.isEmpty {
                toolbar
                Divider()
            }
            history
            Divider()
            composer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: isResponding) { _, responding in
            respondingSince = responding ? Date() : nil
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack {
            Spacer()
            Button {
                isConfirmingClear = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            // Disabled mid-answer: that call appends its result when it lands, which would bring
            // back a history just cleared.
            .disabled(isResponding)
            .help("チャット履歴をクリア")
            .accessibilityLabel("チャット履歴をクリア")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        // Confirmed, not undoable: the history is deleted from disk, and there is no other copy.
        .confirmationDialog("このセッションのチャット履歴を削除しますか？", isPresented: $isConfirmingClear) {
            Button("削除", role: .destructive) { onClear() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("質問と回答がすべて消えます。元に戻せません。会議の書き起こしとサマリはそのまま残ります。")
        }
    }

    // MARK: History

    /// The whole conversation, drawn by `web/src/chat.ts` (design 39 §3.6). Everything the SwiftUI
    /// version kept in `@State` for this area -- pin-to-bottom tracking, the auto-scroll suppression
    /// window, the elapsed-seconds ticker -- now lives in the page, which is also where the copy and
    /// retry buttons are. `TranscriptAutoFollow` stays in the codebase for the transcript tab, and
    /// `chat.ts` reimplements the same rule against the DOM's scrolling model.
    private var history: some View {
        ChatWebView(
            host: markdownHost,
            turns: turns.map(ChatTurnView.init(turn:)),
            isResponding: isResponding,
            respondingSince: respondingSince,
            copyFeedbackTurnId: copyFeedbackTurnId,
            onCopy: onCopy,
            onRetry: onRetry,
            onOpenSegment: onOpenSegment
        )
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .trailing, spacing: 6) {
            // `PlainTextEditor`, not a bare `TextEditor`: it already solves the two things this
            // field needs. Its placeholder is positioned against the `NSTextView`'s own text origin
            // (a hand-layered overlay has to guess that inset, and guessed wrong here -- the
            // placeholder sat a line below the caret), and its `updateNSView` refuses to touch the
            // string while an IME composition is in flight, which is what keeps fast Japanese input
            // from dropping characters. A chat composer is a Japanese-input field, so that matters
            // as much here as it does in the Prep tab.
            //
            // Multi-line, and Return inserts a newline rather than sending: questions written during
            // a meeting are often several lines long, so ⌘⏎ is the send gesture (§3.5).
            PlainTextEditor(
                text: $draft,
                isEditable: !isResponding,
                placeholder: "質問を入力…"
            )
            .frame(minHeight: 56, maxHeight: 120)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))

            Button("送信") { onSend() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!ChatComposer.canSend(draft: draft, isResponding: isResponding))
                .help("質問を送信 (⌘⏎)")
                .accessibilityLabel("質問を送信")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
