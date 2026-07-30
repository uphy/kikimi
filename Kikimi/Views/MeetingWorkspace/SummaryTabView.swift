import SwiftUI

// MARK: - SummaryTabView

/// Summary tab of the Session Window window (`docs/design/06-ui-panels.md` section 6.4,
/// `docs/design/04-summary-updater.md` section 5.1/7).
///
/// Now a **live view**: `MeetingWorkspaceViewModel` owns the `SummaryUpdater` subscription and
/// publishes `summaryMarkdown`, so this view just renders whatever `String?` it's handed -- no file
/// I/O, no `@State`, no `.task` (previously a Phase 1 stub that read `summary.md` once via
/// `sessionHandle.readText(.summaryMarkdown)`; `04-summary-updater.md` landing removes that stub).
///
/// The "サマリ全文再生成" button (kikimi.md section 8) is now shown, per section 6.4: "「サマリ全文再生成」
/// ボタンは `04-summary-updater.md` 実装後まで非表示にする" -- that condition is now satisfied.
///
/// Rendering goes through `MarkdownWebView` (`docs/design/39-webview-markdown.md`): `summary.md`
/// contains headings, lists, and a GFM table (the action items table, `04-summary-updater.md`
/// section 5.1's view template), and now also mermaid diagrams, none of which
/// `Text`/`AttributedString(markdown:)` can render. MarkdownUI — and the `Theme.summary` that used
/// to live in this file — is gone as of design 39's Phase C: every Markdown surface renders through
/// the web view now, and keeping a second renderer alive would mean maintaining both.
struct SummaryTabView: View {
    let summaryMarkdown: String?
    let onRegenerate: () async -> Void
    /// The window-lifetime web view this tab renders into (`docs/design/39-webview-markdown.md`
    /// MD2), handed down from `MeetingWorkspaceWindowController`'s `MarkdownWebViewStore`.
    @ObservedObject var markdownHost: MarkdownWebViewHost

    @State private var isRegenerating = false

    var body: some View {
        VStack(spacing: 0) {
            // `docs/design/17-session-window-redesign.md` §5.6/B-6: no summary has ever been
            // generated yet, so there's nothing to regenerate from (Draft/early-Recording, before
            // the first `SummaryUpdater` run) -- hide the button rather than offer an action that
            // would just no-op/error.
            if summaryMarkdown != nil {
                regenerateBar
                Divider()
            }

            if let summaryMarkdown, !summaryMarkdown.isEmpty {
                MarkdownWebView(host: markdownHost, markdown: summaryMarkdown, docKey: "summary")
            } else {
                SummaryPlaceholder()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var regenerateBar: some View {
        HStack {
            Spacer()
            Button {
                guard !isRegenerating else { return }
                isRegenerating = true
                Task {
                    await onRegenerate()
                    isRegenerating = false
                }
            } label: {
                if isRegenerating {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("再生成中…")
                    }
                } else {
                    Text("サマリ全文再生成")
                }
            }
            .disabled(isRegenerating)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - SummaryPlaceholder

/// "サマリはまだ生成されていません" placeholder (section 6.4), shown whenever `summaryMarkdown` is `nil`
/// or empty (no update has completed yet). Mirrors `SettingsPlaceholderTab`'s layout
/// (`Kikimi/Views/SettingsView.swift`) for visual consistency across Phase 1 stub tabs.
private struct SummaryPlaceholder: View {
    var body: some View {
        VStack {
            Spacer()
            Text("サマリはまだ生成されていません")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
