import SwiftUI

// MARK: - LLMUsageBadge

/// Header cost badge (`docs/design/16-llm-usage-stats.md` section 5): a small, understated button
/// showing the session's cumulative estimated LLM cost, opening a popover with the full breakdown
/// on click. `MeetingWorkspaceView`'s header only shows this once `summary.overall.callCount > 0`
/// (design section 5's "呼び出しが 1 件以上あるときだけ表示"), mirroring `AudioInputPopoverButton`'s
/// placement immediately before `recordingControl`.
struct LLMUsageBadge: View {
    let summary: LLMUsageSummary
    /// AX name/help text for this badge instance. Defaults to the Session Window header's wording;
    /// `SessionListView`'s all-time footer badge passes a distinct label ("LLM 使用状況（全体）") so
    /// `kikimi-verify`/System Events AX-name lookups can tell the two badges apart when both windows
    /// happen to be open at once (`docs/design/16-llm-usage-stats.md` section 5).
    var accessibilityLabel: String = "LLM 使用状況"
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "dollarsign.circle")
                Text(Self.formattedCost(summary.overall.costUSD))
                    .monospacedDigit()
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // AX contract for `kikimi-verify`/System Events scripting: `.help` backs AppleScript's
        // `get help of button`, `.accessibilityLabel` backs AX name lookups (same convention as
        // `AudioInputPopoverButton`/`RecordingControlView` in `MeetingWorkspaceView.swift`).
        .help(accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            LLMUsageDetailView(summary: summary)
        }
    }

    /// `docs/design/16-llm-usage-stats.md` section 5: `$1`未満は4桁小数（`$0.0123`）、以上は2桁（`$1.23`）。
    static func formattedCost(_ costUSD: Double) -> String {
        if abs(costUSD) < 1 {
            return String(format: "$%.4f", costUSD)
        }
        return String(format: "$%.2f", costUSD)
    }
}

// MARK: - LLMUsageDetailView

/// The popover body: overall totals, a per-purpose cost breakdown, and an "unknown cost" footnote
/// when applicable (design section 5).
private struct LLMUsageDetailView: View {
    let summary: LLMUsageSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("LLM 使用状況")
                .font(.headline)

            overallSection

            if !summary.byPurpose.isEmpty {
                Divider()
                byPurposeSection
            }

            if summary.overall.unknownCostCallCount > 0 {
                Text("価格不明の呼び出し: \(summary.overall.unknownCostCallCount) 件")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(minWidth: 220, maxWidth: 320, alignment: .leading)
    }

    private var overallSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledRow(label: "呼び出し回数", value: "\(summary.overall.callCount)")
            LabeledRow(label: "コスト", value: LLMUsageBadge.formattedCost(summary.overall.costUSD))
            LabeledRow(label: "入力トークン", value: "\(summary.overall.inputTokens)")
            LabeledRow(label: "出力トークン", value: "\(summary.overall.outputTokens)")
            LabeledRow(label: "キャッシュ読込", value: "\(summary.overall.cacheReadInputTokens)")
            LabeledRow(label: "キャッシュ書込", value: "\(summary.overall.cacheCreationInputTokens)")
        }
    }

    private var byPurposeSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("用途別")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            // Sorted for a deterministic, stable popover layout across re-renders (dictionaries
            // have no defined iteration order).
            ForEach(summary.byPurpose.keys.sorted(), id: \.self) { purpose in
                if let totals = summary.byPurpose[purpose] {
                    LabeledRow(label: Self.displayLabel(forPurpose: purpose), value: LLMUsageBadge.formattedCost(totals.costUSD))
                }
            }
        }
    }

    /// `docs/design/16-llm-usage-stats.md` section 5's UI wording: `LLMRequest.stubKey`/
    /// `LLMUsageRecord.purpose` values are internal dispatch keys, not user-facing labels
    /// (`refinement`/`summary_patch`/`final_title`), so this maps the known keys to their Japanese
    /// display names and falls back to the raw key for anything else (e.g. a future Watcher
    /// `stubKey`).
    private static func displayLabel(forPurpose purpose: String) -> String {
        switch purpose {
        case "refinement":
            return "整形"
        case "summary_patch":
            return "サマリ"
        case "final_title":
            return "タイトル"
        case "dictation":
            // `docs/design/29-dictation-history.md` section 6.3: the dictation history window's
            // footer reuses this same popover for its "保持中の履歴 N 件の合計" breakdown, and
            // `DictationRefiner`'s existing stubKey (`DictationRefiner.swift`) -- which doubles as
            // `LLMUsageRecord.purpose` per this type's own convention -- is the fixed string
            // "dictation".
            return "音声入力整形"
        case "chat":
            // `docs/design/38-session-chat.md` CH11: `ChatRunner` sets `stubKey: "chat"`, which
            // `UsageRecordingLLM` records as the `purpose`, so chat cost shows up as its own row
            // here instead of being pooled into the `unknown` fallback.
            return "チャット"
        default:
            return purpose
        }
    }
}

// MARK: - LabeledRow

private struct LabeledRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .monospacedDigit()
        }
        .font(.callout)
    }
}
