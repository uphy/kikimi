import MarkdownUI
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
/// Rendering uses MarkdownUI's `Markdown` view (kikimi.md section 13 / docs/development-process.md
/// section 2.2 lists it as the approved Markdown preview option) rather than a plain `Text`, since `summary.md` contains
/// headings, lists, and a GFM table (the action items table, `04-summary-updater.md` section
/// 5.1's view template) that `Text`/`AttributedString(markdown:)` cannot render. The theme is
/// `Theme.gitHub` with the `.text` style stripped of its background color (`Theme.summary` below)
/// so the rendered content blends into the tab's own background instead of painting its own
/// light/dark box -- this floating panel has no distinct "card" chrome to render onto.
struct SummaryTabView: View {
    let summaryMarkdown: String?
    let onRegenerate: () async -> Void

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
                ScrollView {
                    Markdown(summaryMarkdown)
                        .markdownTheme(.summary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
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

// MARK: - Theme.summary

extension Theme {
    /// `Theme.gitHub` (docs/development-process.md 2.2's approved MarkdownUI theme starting point) with two
    /// adjustments for the Summary tab's floating-panel context:
    ///
    /// - The `.text` style drops `Theme.gitHub`'s explicit `BackgroundColor(.background)` (a
    ///   fixed white/near-black rectangle painted behind every text run) so the rendered Markdown
    ///   shows through to whatever the tab's own background is, rather than layering a second,
    ///   slightly different light/dark box on top of it.
    /// - The base `FontSize` is lowered from GitHub's 16pt default to 13pt to match `.body`
    ///   (the font every other Session Window tab, e.g. `TranscriptTabView`, renders its primary
    ///   text at) instead of looking oversized next to them. Headings/code/etc. still scale off
    ///   this base via `Theme.gitHub`'s `.em(...)` multipliers, so their relative proportions are
    ///   unchanged.
    static let summary = Theme.gitHub
        .text {
            ForegroundColor(.primary)
            FontSize(13)
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
