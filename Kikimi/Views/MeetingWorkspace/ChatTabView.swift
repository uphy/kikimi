import MarkdownUI
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
/// contract `TranscriptTabView`/`WatchersTabView` keep. Auto-follow reuses `TranscriptAutoFollow`
/// rather than reimplementing it: this is the identical "stay pinned to the bottom until the user
/// scrolls away" problem, and two implementations of it would drift.
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

    @State private var isPinnedToBottom = true
    @State private var isAutoScrolling = false
    /// When the in-flight answer was requested, for the "…秒" counter. `nil` when idle.
    @State private var respondingSince: Date?

    private static let bottomAnchorID = "ChatTabView.bottomAnchor"

    var body: some View {
        VStack(spacing: 0) {
            history
            Divider()
            composer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: isResponding) { _, responding in
            respondingSince = responding ? Date() : nil
        }
    }

    // MARK: History

    private var history: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if turns.isEmpty {
                        emptyPlaceholder
                    } else {
                        ForEach(turns) { turn in
                            turnRow(turn).id(turn.id)
                        }
                    }
                    if isResponding {
                        pendingRow
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchorID)
                        .onAppear { isPinnedToBottom = true }
                        .onDisappear {
                            guard TranscriptAutoFollow.shouldUnpin(isAutoScrolling: isAutoScrolling) else { return }
                            isPinnedToBottom = false
                        }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // The restored history arrives as the first `turns` value, before any `onChange` fires,
            // so the initial jump to the newest turn belongs here (same as `TranscriptTabView`).
            .onAppear { scrollToBottom(proxy: proxy, animated: false) }
            .onChange(of: turns) { _, _ in scrollToBottomIfPinned(proxy: proxy) }
            .onChange(of: isResponding) { _, _ in scrollToBottomIfPinned(proxy: proxy) }
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func turnRow(_ turn: ChatTurn) -> some View {
        switch turn.role {
        case .user:
            userBubble(turn)
        case .assistant:
            assistantBubble(turn)
        }
    }

    private func userBubble(_ turn: ChatTurn) -> some View {
        HStack {
            Spacer(minLength: 40)
            Text(turn.text)
                .font(.body)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.15))
                .cornerRadius(8)
        }
    }

    @ViewBuilder
    private func assistantBubble(_ turn: ChatTurn) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // §4.5: shown per answer, not per session, so reading an old exchange still explains why
            // that particular answer had less to work from.
            if turn.contextScope == .summaryAndRecent {
                demotionLabel
            }

            if let error = turn.error {
                failureRow(turn: turn, error: error)
            } else {
                Markdown(turn.text)
                    .markdownTheme(.summary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                answerFooter(turn)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(8)
    }

    private var demotionLabel: some View {
        Label("会議が長いため、サマリと直近の会話をもとに回答しています", systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func failureRow(turn: ChatTurn, error: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("回答を取得できませんでした: \(error)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("再送") { onRetry(turn.id) }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                // AX contract for `kikimi-verify`/System Events scripting, same convention as the
                // header's "タイトル案を採用": keep `.help` and `.accessibilityLabel` identical.
                .help("回答を再送")
                .accessibilityLabel("回答を再送")
        }
    }

    private func answerFooter(_ turn: ChatTurn) -> some View {
        HStack(spacing: 8) {
            Spacer()
            Button {
                onCopy(turn.id)
            } label: {
                Image(systemName: copyFeedbackTurnId == turn.id ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("回答をコピー")
            .accessibilityLabel("回答をコピー")
            Text(Self.timeFormatter.string(from: turn.createdAt))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    /// Stands in for the answer while the call is in flight. No streaming: `LLMBackend` exposes a
    /// single `complete` (CH7), so there is nothing to show progressively -- the elapsed seconds are
    /// there so a slow answer does not look like a hang.
    private var pendingRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            if let respondingSince {
                TimelineView(.periodic(from: respondingSince, by: 1)) { context in
                    Text("回答を作成中… \(Int(context.date.timeIntervalSince(respondingSince)))秒")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            } else {
                Text("回答を作成中…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var emptyPlaceholder: some View {
        Text("この会議について質問できます（例: ここまでの決定事項は？）")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 24)
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

    // MARK: Scrolling

    private func scrollToBottomIfPinned(proxy: ScrollViewProxy) {
        guard TranscriptAutoFollow.shouldFollow(isPinnedToBottom: isPinnedToBottom) else { return }
        scrollToBottom(proxy: proxy, animated: true)
    }

    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool) {
        guard !turns.isEmpty || isResponding else { return }
        isAutoScrolling = true
        if animated {
            withAnimation(.easeOut(duration: TranscriptAutoFollow.scrollAnimationDuration)) {
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(TranscriptAutoFollow.autoScrollSettleDuration))
            isAutoScrolling = false
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
