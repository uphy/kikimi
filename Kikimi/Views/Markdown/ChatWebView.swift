import SwiftUI

// MARK: - ChatWebView

/// The chat history, rendered as one page (`docs/design/39-webview-markdown.md` MD4 / §3.6).
///
/// Unlike `MarkdownWebView` this owns more than a body: the bubbles, the copy/retry buttons, the
/// pending spinner, and the auto-follow behaviour all live in `web/src/chat.ts`. That is the price of
/// not creating one web view per answer.
///
/// The composer and the "clear history" toolbar stay in SwiftUI (`ChatTabView`) — the composer's IME
/// handling (`PlainTextEditor`) is worth keeping.
struct ChatWebView: View {
    @ObservedObject var host: MarkdownWebViewHost

    /// Already folded by `ChatTurnLog.fold(_:)`, oldest first.
    let turns: [ChatTurnView]
    let isResponding: Bool
    /// When the in-flight answer was requested, for the page's elapsed-seconds counter.
    let respondingSince: Date?
    let copyFeedbackTurnId: String?
    var onCopy: (String) -> Void = { _ in }
    var onRetry: (String) -> Void = { _ in }
    var onOpenSegment: (String) -> Void = { _ in }

    var body: some View {
        Group {
            if case .failed(let reason) = host.state {
                ChatPlainTextFallback(turns: turns, reason: reason, onRetry: onRetry)
            } else {
                MarkdownWebViewRepresentable(host: host) { host in
                    host.onCopyTurn = onCopy
                    host.onRetryTurn = onRetry
                    host.onOpenSegment = onOpenSegment
                    host.setTurns(turns)
                    host.setResponding(isResponding, since: respondingSince)
                    host.setCopyFeedback(turnId: copyFeedbackTurnId)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - ChatPlainTextFallback

/// design 39 MD15, chat flavour. The document fallback can get away with dumping Markdown as text,
/// but chat cannot: the retry button lives in the page, and losing it would leave a failed answer
/// with no way back other than retyping the question. So the failure rows keep their buttons here,
/// in SwiftUI.
private struct ChatPlainTextFallback: View {
    let turns: [ChatTurnView]
    let reason: String
    let onRetry: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("表示コンポーネントを読み込めませんでした。本文をそのまま表示しています。", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .help(reason)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(turns, id: \.id) { turn in
                        row(turn)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func row(_ turn: ChatTurnView) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(turn.role == "user" ? "質問" : "回答")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if let error = turn.error {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("回答を取得できませんでした: \(error)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("再送") { onRetry(turn.id) }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .help("回答を再送")
                        .accessibilityLabel("回答を再送")
                }
            } else {
                Text(turn.text)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
