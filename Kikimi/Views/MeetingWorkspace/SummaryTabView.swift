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
    let summaryMarkdown: SummaryMarkdown?
    /// `docs/design/44-llm-model-config.md` §8: `nil` for "既定で実行", otherwise the resolved
    /// override the manual-override menu built (an alias resolution or the "モデルを指定して実行…"
    /// sheet's provider+model).
    let onRegenerate: (ResolvedModel?) async -> Void
    /// `true` only for an Ended session (`meta.state == .ended`) -- gates the "最終整形を再実行" button,
    /// which §8 scopes to Ended sessions specifically.
    let isEnded: Bool
    /// `docs/design/44-llm-model-config.md` §8's "既定" labels -- session-start-snapshotted resolved
    /// model names, one per button (`MeetingWorkspaceViewModel.summaryDefaultModelLabel`/
    /// `summaryFinalPassDefaultModelLabel`).
    let defaultRegenerateModelLabel: String
    let defaultFinalPassModelLabel: String
    /// Live config the manual-override menus read `llm.models`/`llm.default` from
    /// (`ModelOverrideMenuButton`'s own `@ObservedObject` doc comment).
    @ObservedObject var appConfig: AppConfig
    let onRerunFinalPass: (ResolvedModel?) async -> Void
    /// The window-lifetime web view this tab renders into (`docs/design/39-webview-markdown.md`
    /// MD2), handed down from `MeetingWorkspaceWindowController`'s `MarkdownWebViewStore`.
    @ObservedObject var markdownHost: MarkdownWebViewHost
    /// The 議事詳細 pane's web view, resolved **lazily** (`docs/design/47-summary-split-pane.md` §4.1).
    ///
    /// A closure rather than a stored `MarkdownWebViewHost` because `MeetingWorkspaceView` builds this
    /// view's arguments during `body` evaluation, before anyone has looked at whether the template
    /// splits. `MarkdownWebViewStore.host(for:)` creates *and* starts loading the 312KB bundle on
    /// first call, so passing it eagerly would cost every session a second `WKWebView` (and its own
    /// WebContent process) even when the pane never appears. The store returns the same host for
    /// repeat calls, so evaluating this on every `body` pass still yields exactly one web view.
    let topicsMarkdownHost: () -> MarkdownWebViewHost

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

            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Three shapes, in decreasing order of how much the template gave us to work with: the two-pane
    /// split, the single pane a template that could not be split falls back to, and the placeholder.
    @ViewBuilder
    private var content: some View {
        if let summaryMarkdown, !summaryMarkdown.joined.isEmpty {
            if let topics = summaryMarkdown.topics {
                // 50:50 to start, freely draggable, not remembered across windows -- §4.2 (the same
                // `NSSplitView` limitation `MeetingTabView`'s `HSplitView` already lives with).
                VSplitView {
                    MarkdownWebView(host: markdownHost, markdown: summaryMarkdown.top, docKey: "summary-top")
                        .frame(minHeight: 120, maxHeight: .infinity)
                    MarkdownWebView(
                        host: topicsMarkdownHost(),
                        markdown: topics,
                        docKey: "summary-topics",
                        // §5.1: following an Ended session's log would drop the reader at the end of a
                        // meeting they are opening to read from the start.
                        followBottom: !isEnded
                    )
                    .frame(minHeight: 120, maxHeight: .infinity)
                }
            } else {
                // A distinct `docKey` from the split layout's top pane on purpose (§4.1): switching
                // between the two means a document of a completely different length, and reusing the
                // key would restore a scroll offset that no longer means anything.
                MarkdownWebView(host: markdownHost, markdown: summaryMarkdown.joined, docKey: "summary")
            }
        } else {
            SummaryPlaceholder()
        }
    }

    private var regenerateBar: some View {
        HStack {
            Spacer()
            // §8: Ended sessions get both actions side by side -- regenerate rebuilds the whole
            // summary from the transcript, final-pass re-run only rewrites overview/decisions/
            // action_items from the current state (`docs/design/summary-quality-topics-and-final-pass.md`
            // §7.1).
            if isEnded {
                ModelOverrideMenuButton(
                    title: "最終整形を再実行",
                    busyTitle: "再実行中…",
                    defaultModelLabel: defaultFinalPassModelLabel,
                    appConfig: appConfig,
                    action: onRerunFinalPass
                )
            }
            ModelOverrideMenuButton(
                title: "サマリ全文再生成",
                busyTitle: "再生成中…",
                defaultModelLabel: defaultRegenerateModelLabel,
                appConfig: appConfig,
                action: onRegenerate
            )
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
