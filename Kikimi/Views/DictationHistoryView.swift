import AppKit
import Foundation
import SwiftUI

// MARK: - DictationHistoryView

/// Content for the dictation history window (`docs/design/29-dictation-history.md` section 6):
/// a single window with a list (left) and a detail pane (right) for one entry at a time (DH8 --
/// unlike Session List's "open a separate window per row" convention).
///
/// Spiked with `NavigationSplitView` per section 6.2's explicit escape hatch ("実装フェーズの最初に
/// `kikimi-verify` でスパイクし、問題があれば `HSplitView` + 手組みの List/detail に切り替えてよい") --
/// only the two-pane shape is load-bearing, not this particular container type.
struct DictationHistoryView: View {
    @ObservedObject var viewModel: DictationHistoryViewModel

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                list
                    .navigationSplitViewColumnWidth(min: 220, ideal: 280)
            } detail: {
                detail
            }
            Divider()
            footer
        }
        .frame(minWidth: 640, minHeight: 420)
        .task {
            viewModel.startObservingHistoryRecorded()
            await viewModel.refresh()
        }
        .onChange(of: viewModel.selectedId) { _, _ in
            Task { await viewModel.loadSelectedEntry() }
        }
    }

    // MARK: List

    private var list: some View {
        Group {
            if viewModel.items.isEmpty {
                emptyState
            } else {
                List(selection: $viewModel.selectedId) {
                    ForEach(viewModel.items, id: \.id) { item in
                        DictationHistoryRow(item: item)
                            .tag(item.id)
                            .contentShape(Rectangle())
                            .contextMenu {
                                // §6.2 addendum: hand the entry folder (audio.wav + entry.json) to
                                // an external tool (e.g. a coding agent investigating a transcription
                                // problem) -- "Finder で開く"/"パスをコピー" both need only the path,
                                // not any store file I/O, so they read it straight off
                                // `DictationHistoryStore`'s pure path helper.
                                Button("Finder で開く") {
                                    NSWorkspace.shared.activateFileViewerSelecting(
                                        [DictationHistoryStore.entryDirectoryURL(forId: item.id)]
                                    )
                                }
                                Button("パスをコピー") {
                                    let pasteboard = NSPasteboard.general
                                    pasteboard.clearContents()
                                    pasteboard.setString(
                                        DictationHistoryStore.entryDirectoryURL(forId: item.id).path,
                                        forType: .string
                                    )
                                }
                                Divider()
                                Button("削除", role: .destructive) {
                                    viewModel.delete(id: item.id)
                                }
                            }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .navigationTitle("ディクテーション履歴")
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "mic.slash")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("ディクテーション履歴はまだありません")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let id = viewModel.selectedId, let entry = viewModel.selectedEntry {
            DictationHistoryDetailView(
                id: id,
                entry: entry,
                isPlaying: viewModel.playingId == id,
                onTogglePlayback: { fileURL, durationMs in
                    viewModel.togglePlayback(id: id, fileURL: fileURL, durationMs: durationMs)
                }
            )
        } else if viewModel.selectedId != nil {
            // Selected but `loadSelectedEntry()` hasn't resolved yet (or failed and cleared itself).
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text("エントリを選択してください")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Footer

    /// Section 6.3: reuses `LLMUsageBadge(summary:)` as-is, with a label making clear this is "保持中
    /// の履歴 N 件の合計", not an all-time total (only shown once at least one retained entry has
    /// recorded LLM usage, mirroring `SessionListView`/`MeetingWorkspaceView`'s "callCount > 0"
    /// gating for their own cost badges).
    private var footer: some View {
        HStack(spacing: 8) {
            if viewModel.retainedSummary.overall.callCount > 0 {
                LLMUsageBadge(summary: viewModel.retainedSummary, accessibilityLabel: "LLM 使用状況（ディクテーション履歴）")
                Text("保持中の履歴\(viewModel.items.count)件の合計")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
    }
}

// MARK: - DictationHistoryRow

/// One list row = one utterance. Two-line layout modeled on `SessionRow`
/// (`SessionListView.swift:382-431`): first line is `finalText`'s first line, second line is
/// timestamp + duration + a status icon (section 6.2).
private struct DictationHistoryRow: View {
    let item: DictationHistoryStore.ListItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(firstLine)
                .lineLimit(1)
                .truncationMode(.tail)

            HStack(spacing: 6) {
                if let status {
                    Image(systemName: status.systemName)
                        .foregroundStyle(status.color)
                        .help(status.help)
                }
                Text(DictationHistoryFormatting.relative(item.recordedAt))
                Text(DictationHistoryFormatting.absolute(item.recordedAt))
                Text(DictationHistoryFormatting.duration(item.durationMs))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    /// `finalText`'s first line, so a multi-line refined utterance doesn't blow out row height.
    private var firstLine: String {
        let line = item.finalText
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? item.finalText
        return line.isEmpty ? "(無音)" : line
    }

    /// Section 6.2: "`refine_outcome` が `fallback` なら警告色、`insert_outcome` が
    /// `aborted_and_stashed` なら中止アイコン" -- fallback (refine 全滅, this feature's original
    /// motivation) takes priority since it is the more actionable signal when both happen to apply
    /// to the same utterance.
    private var status: (systemName: String, color: Color, help: String)? {
        if item.refineOutcome == DictationHistoryRefineOutcome.fallback.rawValue {
            return ("exclamationmark.triangle.fill", .orange, "整形に失敗し、未整形のテキストを使用しました")
        }
        if item.insertOutcome == DictationHistoryInsertOutcome.abortedAndStashed.rawValue {
            return ("arrow.uturn.left.circle.fill", .secondary, "挿入を中止し、クリップボードへ退避しました")
        }
        return nil
    }
}

// MARK: - DictationHistoryDetailView

/// The detail pane for one selected entry (section 6.2): playback, raw/refined text, insert
/// target/outcome, and this utterance's own cost/token breakdown.
private struct DictationHistoryDetailView: View {
    let id: String
    let entry: DictationHistoryEntry
    let isPlaying: Bool
    let onTogglePlayback: (_ fileURL: URL, _ durationMs: Int) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                playbackRow
                Divider()
                textSection
                Divider()
                insertSection
                if let llmUsage = entry.llmUsage {
                    Divider()
                    costSection(llmUsage)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // AX contract for `kikimi-verify`: lets the detail pane be located/asserted on by name
        // per entry, the same convention `LLMUsageBadge`'s `.help`/`.accessibilityLabel` documents.
        .accessibilityLabel("ディクテーション履歴詳細 \(id)")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(DictationHistoryFormatting.absolute(entry.recordedAt))
                .font(.headline)
            Text(DictationHistoryFormatting.duration(entry.durationMs))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// DH9: `audio.wav` may not exist (writer init failure, `history.enabled` toggled off
    /// mid-utterance, etc.) -- the play button is disabled with a "音声なし" note in that case
    /// (section 6.2), rather than attempting playback and failing silently.
    private var audioFileURL: URL {
        DictationHistoryStore.audioFileURL(forId: id)
    }

    private var hasAudio: Bool {
        FileManager.default.fileExists(atPath: audioFileURL.path)
    }

    private var playbackRow: some View {
        HStack(spacing: 8) {
            Button {
                onTogglePlayback(audioFileURL, entry.durationMs)
            } label: {
                Label(isPlaying ? "停止" : "再生", systemImage: isPlaying ? "stop.fill" : "play.fill")
            }
            .disabled(!hasAudio)

            if !hasAudio {
                Text("音声なし")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Raw/refined side-by-side on success; raw only (plus a failure badge) otherwise (section 6.2:
    /// "raw/refined 並記（fallback 時は raw のみ + refine_error バッジ）"). `disabled` (D1's
    /// `dictation.refine == false`, DH12) also falls into the "raw only" branch, with no badge --
    /// there is no error to show, `final_text` is simply raw by design.
    private var textSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            labeledText(title: "音声認識結果（raw）", text: entry.rawText)

            // design 31 §3.4: the streaming decoder's text is a collapsed diagnostic aside, shown
            // only when the batch re-decode supplied `raw_text` (otherwise `raw_text` *is* the
            // streaming text and there is nothing extra to show).
            if let streamingText = entry.streamingText {
                DisclosureGroup("ストリーミング（参考）") {
                    Text(streamingText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if entry.refineOutcome == .success, let refinedText = entry.refinedText {
                labeledText(title: "整形後", text: refinedText)
            } else if entry.refineOutcome == .fallback, let refineError = entry.refineError {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("整形に失敗しました: \(refineError)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func labeledText(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(text)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var insertSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            DetailRow(label: "挿入先アプリ", value: entry.targetBundleId ?? "不明")
            DetailRow(label: "挿入結果", value: insertOutcomeLabel)
            // design 29 §3.2 addendum: absent entirely (not "不明") on pre-existing `entry.json`
            // files recorded before `mic_device_name` existed -- there is nothing meaningful to show
            // for those, unlike `targetBundleId` which can genuinely be "取得できなかった" at capture
            // time even on a current entry.
            if let micDeviceName = entry.micDeviceName {
                DetailRow(label: "マイク", value: micDeviceName)
            }
        }
    }

    private var insertOutcomeLabel: String {
        switch entry.insertOutcome {
        case .inserted:
            return "挿入済み"
        case .abortedAndStashed:
            return "挿入を中止（クリップボードへ退避）"
        }
    }

    /// Section 6.2: "この発話の cost とトークン内訳（`llm_usage` から `LLMPricing.estimatedCostUSD`
    /// で単発計算 ... 4 区分をそのまま出す）". Rather than reimplementing the
    /// reported-cost-wins-else-estimate priority rule, this reuses
    /// `LLMUsageAggregator.summarize(records:configPricing:)` on a single-element array -- the exact
    /// same pure aggregation `DictationHistoryViewModel.retainedSummary`/`LLMUsageBadge` already rely
    /// on, just scoped to one record.
    private func costSection(_ usage: LLMUsageRecord) -> some View {
        let totals = LLMUsageAggregator.summarize(
            records: [usage],
            configPricing: AppConfig.shared.data.llm.pricing
        ).overall
        return VStack(alignment: .leading, spacing: 4) {
            Text("LLM 使用量")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            DetailRow(label: "コスト", value: LLMUsageBadge.formattedCost(totals.costUSD))
            DetailRow(label: "入力トークン", value: "\(totals.inputTokens)")
            DetailRow(label: "出力トークン", value: "\(totals.outputTokens)")
            DetailRow(label: "キャッシュ読込", value: "\(totals.cacheReadInputTokens)")
            DetailRow(label: "キャッシュ書込", value: "\(totals.cacheCreationInputTokens)")
        }
    }
}

// MARK: - DetailRow

private struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
        .font(.callout)
    }
}

// MARK: - DictationHistoryFormatting

/// Pure display-formatting helpers, kept free of view state so they stay directly unit-testable
/// (mirrors `SessionListFormatting`'s rationale, `SessionListView.swift:452`).
enum DictationHistoryFormatting {
    /// e.g. "3分前" -- section 6.2's "日時（相対 + 絶対）" pairs this with `absolute(_:)`.
    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// e.g. "2026-07-10 09:15:32" -- second-resolution (unlike `SessionListFormatting.timestamp`'s
    /// minute-resolution) since multiple dictation utterances can land within the same minute.
    static func absolute(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    /// e.g. `4210` ms -> `"0:04"`. Dictation utterances are short (a few seconds to perhaps a
    /// couple of minutes), so this always renders `m:ss` rather than `SessionListFormatting
    /// .duration(_:)`'s `h`/`m`-only format meant for whole meetings.
    static func duration(_ milliseconds: Int) -> String {
        let totalSeconds = max(0, milliseconds) / 1_000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
