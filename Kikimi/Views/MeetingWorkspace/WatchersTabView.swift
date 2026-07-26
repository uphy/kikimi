import MarkdownUI
import SwiftUI

// MARK: - WatchersTabView

/// Watchers tab of the Session Window window (`docs/design/06-ui-panels.md` section 6.4,
/// `docs/design/05-watcher-runner.md` §10.2).
///
/// Renders every enabled Watcher (`items`, `MeetingWorkspaceViewModel.watcherItems`) as a sub-tab: a
/// name button with a running/error badge, the latest view-template rendering as Markdown (reusing
/// `SummaryTabView`'s `Theme.summary`), and a footer with a relative "N分前更新" timestamp / error
/// message plus a manual "今すぐ実行" trigger. `kikimi-seg:` links produced by
/// `WatcherViewRenderer.render(...)`'s seg-id linkification (§8.1) are intercepted via
/// `.environment(\.openURL, ...)` and forwarded to `onOpenSegment` rather than being handed to the
/// system (which has no handler for that scheme).
///
/// Has **no compile-time dependency on `MeetingWorkspaceViewModel`** (same decoupling as
/// `PrepContentView`/`TranscriptTabView`): `MeetingWorkspaceView` wires `viewModel.watcherItems`/
/// `$viewModel.selectedWatcherId`/`viewModel.runWatcherNow(id:)`/`viewModel.jumpToTranscriptSegment(_:)`
/// straight into this view's initializer.
///
/// `docs/design/17-session-window-redesign.md` §5.4/R5: now also embeds the Watcher management UI
/// (`WatcherManagementSection`, moved here from the old `PrepTabView`'s Watchers section) --
/// directly in the empty-state body (no enabled Watcher yet, so there's nothing else to show), or
/// behind a collapsed "管理" `DisclosureGroup` beneath the results once at least one Watcher is
/// enabled.
struct WatchersTabView: View {
    var items: [WatcherPanelItem]
    @Binding var selectedWatcherId: String?
    var onRunNow: (String) -> Void
    var onOpenSegment: (String) -> Void

    // MARK: Watchers management (`docs/design/05-watcher-runner.md` §10.3), forwarded verbatim to
    // `WatcherManagementSection`.

    var onSetWatcherEnabled: (_ id: String, _ enabled: Bool) -> Void = { _, _ in }
    var onForkPresetWatcher: (_ id: String) async -> Void = { _ in }
    var presetExists: (_ id: String) -> Bool = { _ in false }
    var onPromoteWatcherToPreset: (_ id: String) async -> Void = { _ in }
    var onCreateLocalWatcher: (_ id: String) async throws -> Void = { _ in }
    var onDeleteLocalWatcher: (_ id: String) async -> Void = { _ in }
    var availablePresets: () -> [String] = { [] }
    var loadWatcherDefinitionText: (_ id: String) async -> String? = { _ in nil }
    var onSaveLocalWatcherText: (_ id: String, _ text: String) async -> String? = { _, _ in nil }

    // MARK: Simple Watcher (`docs/design/34-simple-watchers.md` section 6.3/7), forwarded verbatim
    // to `WatcherManagementSection`.

    var loadSimpleWatcherSpec: (_ id: String) async -> SimpleWatcherSpec? = { _ in nil }
    var onCreateSimpleWatcher: (_ draft: SimpleWatcherSpecDraft) async throws -> Void = { _ in }
    var onUpdateSimpleWatcher: (_ id: String, _ draft: SimpleWatcherSpecDraft) async throws -> Void = { _, _ in }
    var onConvertSimpleWatcherToFull: (_ id: String) async throws -> Void = { _ in }

    var body: some View {
        Group {
            if items.isEmpty {
                emptyPlaceholder
            } else {
                VStack(spacing: 0) {
                    subtabBar
                    Divider()
                    if let selected = selectedItem {
                        content(for: selected)
                    }
                    Divider()
                    managementDisclosure
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var managementSection: some View {
        WatcherManagementSection(
            watcherItems: items,
            onSetWatcherEnabled: onSetWatcherEnabled,
            onForkPresetWatcher: onForkPresetWatcher,
            presetExists: presetExists,
            onPromoteWatcherToPreset: onPromoteWatcherToPreset,
            onCreateLocalWatcher: onCreateLocalWatcher,
            onDeleteLocalWatcher: onDeleteLocalWatcher,
            availablePresets: availablePresets,
            loadWatcherDefinitionText: loadWatcherDefinitionText,
            onSaveLocalWatcherText: onSaveLocalWatcherText,
            loadSimpleWatcherSpec: loadSimpleWatcherSpec,
            onCreateSimpleWatcher: onCreateSimpleWatcher,
            onUpdateSimpleWatcher: onUpdateSimpleWatcher,
            onConvertSimpleWatcherToFull: onConvertSimpleWatcherToFull
        )
    }

    private var managementDisclosure: some View {
        DisclosureGroup("管理") {
            managementSection
                .padding(.top, 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var selectedItem: WatcherPanelItem? {
        items.first { $0.id == selectedWatcherId } ?? items.first
    }

    private var subtabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(items) { item in
                    subtabButton(for: item)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }

    private func subtabButton(for item: WatcherPanelItem) -> some View {
        let isSelected = selectedItem?.id == item.id
        return Button {
            selectedWatcherId = item.id
        } label: {
            HStack(spacing: 4) {
                Text(item.name)
                statusBadge(for: item.status)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .cornerRadius(6)
        .help(item.name)
    }

    @ViewBuilder
    private func statusBadge(for status: WatcherPanelItem.Status) -> some View {
        switch status {
        case .idle:
            EmptyView()
        case .running:
            ProgressView()
                .controlSize(.mini)
                .accessibilityLabel("実行中")
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
                .accessibilityLabel("エラー")
        }
    }

    private func content(for item: WatcherPanelItem) -> some View {
        VStack(spacing: 0) {
            if let markdown = item.renderedMarkdown, !markdown.isEmpty {
                ScrollView {
                    Markdown(markdown)
                        .markdownTheme(.summary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .environment(\.openURL, OpenURLAction { url in
                    // `docs/design/05-watcher-runner.md` §10.4: the `kikimi-seg:` scheme is handled
                    // entirely within this view -- it is never registered on `KikimiURLRoute`.
                    guard url.scheme == "kikimi-seg" else { return .systemAction }
                    onOpenSegment(url.absoluteString.replacingOccurrences(of: "kikimi-seg:", with: ""))
                    return .handled
                })
            } else {
                WatcherNoResultPlaceholder()
            }

            Divider()
            footer(for: item)
        }
    }

    private func footer(for item: WatcherPanelItem) -> some View {
        HStack {
            footerStatusText(for: item)
            Spacer()
            Button("今すぐ実行") {
                onRunNow(item.id)
            }
            .disabled(item.status == .running)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func footerStatusText(for item: WatcherPanelItem) -> some View {
        switch item.status {
        case .error(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(1)
        case .running, .idle:
            if let lastRunAt = item.lastRunAt {
                Text(Self.relativeTimeText(lastRunAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("未実行")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// `docs/design/17-session-window-redesign.md` §5.4/§6: the old redirect-to-Prep-tab copy is
    /// dropped (that tab no longer even hosts the management UI, R5) in favor of a description of
    /// what Watchers are for, plus the management section directly -- there's nowhere else to go
    /// from here now.
    private var emptyPlaceholder: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("この会議で追跡したい観点（TODO 追跡・確認事項チェックなど）を追加できます。")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                managementSection
            }
            .padding()
        }
    }

    private static func relativeTimeText(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date()) + "更新"
    }
}

// MARK: - WatcherNoResultPlaceholder

private struct WatcherNoResultPlaceholder: View {
    var body: some View {
        VStack {
            Spacer()
            Text("まだ実行結果がありません")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
