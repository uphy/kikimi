import OSLog
import SwiftUI

/// Root view of the Settings window (`docs/design/06-ui-panels.md` 8章 /
/// `docs/design/26-settings-ui.md` §4, full config-backed scope).
///
/// "一般" (`GeneralSettingsTab`) / "モデル" (`ModelSettingsTab`) / "Watchers"
/// (`WatchersSettingsTab`) bind directly to `AppConfig.shared`, reading/writing `config.yaml`
/// in place -- see `docs/design/26-settings-ui.md` §4.1 for why these tabs skip
/// `SettingsViewModel` entirely (no derived state, just a config.yaml passthrough).
///
/// The "話者" tab is the exception: it is the R2 voiceprint management UI carved out by
/// `docs/design/13-speaker-diarization.md` section 14 ("Settings に一覧 + 削除の最小限のみ"), and is
/// backed by `VoiceprintStore` rather than `AppConfig.shared`.
struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel

    /// Owns tab selection explicitly rather than relying on `TabView`'s implicit internal state.
    /// Without this, `VoiceprintSpeakersTab`'s `.task` publishing `viewModel`'s `@Published`
    /// properties shortly after the window appears re-evaluates this view (the `TabView` observes
    /// the same `viewModel`) and resets an unbound `TabView`'s selection back to its first tab --
    /// which is exactly the "first tab click after opening Settings snaps back to 一般" bug this
    /// binding fixes.
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsTab()
                .tabItem { Text("一般") }
                .tag(0)

            ModelSettingsTab(viewModel: viewModel)
                .tabItem { Text("モデル") }
                .tag(1)

            WatchersSettingsTab()
                .tabItem { Text("Watchers") }
                .tag(2)

            VoiceprintSpeakersTab(viewModel: viewModel)
                .tabItem { Text("話者") }
                .tag(3)

            GlossarySettingsTab()
                .tabItem { Text("用語集") }
                .tag(4)

            DictationSettingsTab()
                .tabItem { Text("入力") }
                .tag(5)
        }
        // No `.padding()` on the TabView itself (docs/design/30-settings-ui-polish.md §5): the
        // grouped forms carry their own insets (padding here doubled the margin), and 用語集's
        // master-detail sidebar wants to reach the tab edges. The one tab without its own insets --
        // 話者 -- pads itself instead.
        //
        // minWidth widened from 420 to 600 for the 5-tab bar (一般/モデル/Watchers/話者/入力,
        // docs/design/25-dictation-mode.md §6 added 入力), then to 680 for the 6th tab (用語集,
        // docs/design/28-glossary.md §4): once the tab bar no longer fits, TabView collapses the
        // overflow into a hidden ">>" menu and the last tabs aren't reachable at the window's default
        // size. 760 now, for 用語集's 160pt category sidebar and its divider on top of that -- the
        // detail pane still needs room for two side-by-side text fields. minHeight raised 380 -> 480
        // for the grouped forms (rows are ~40pt tall; at 380 the 一般 tab couldn't show its first
        // section whole).
        .frame(minWidth: 760, minHeight: 480)
    }
}

// MARK: - AppConfig field binding helper

/// Generic `KikimiConfigData` field binding shared by every config-backed Settings tab
/// (`GeneralSettingsTab`/`ModelSettingsTab`/`WatchersSettingsTab`, `docs/design/26-settings-ui.md`
/// §4.2-§4.4): get reads `data[keyPath:]`, set writes it back through `update`. Written once via
/// `KeyPath` here instead of duplicating this three-line `Binding` per field per tab (the design
/// doc's draft had each tab carry its own copy; consolidated during implementation).
extension AppConfig {
    func binding<Value>(_ keyPath: WritableKeyPath<KikimiConfigData, Value>) -> Binding<Value> {
        Binding(
            get: { self.data[keyPath: keyPath] },
            set: { newValue in self.update { $0[keyPath: keyPath] = newValue } }
        )
    }

    /// Variant for `String?` fields (currently only `llm.claude.cliPath`): a `TextField` needs a
    /// non-optional `String` binding, so an empty field round-trips to `nil` (the "空欄で自動検出/無効"
    /// convention every optional path/string field in `config.yaml` already uses).
    func optionalStringBinding(_ keyPath: WritableKeyPath<KikimiConfigData, String?>) -> Binding<String> {
        Binding(
            get: { self.data[keyPath: keyPath] ?? "" },
            set: { newValue in self.update { $0[keyPath: keyPath] = newValue.isEmpty ? nil : newValue } }
        )
    }
}

// MARK: - WatchersSettingsTab

/// The "Watchers" tab: `watchers.presets_dir` / `watchers.default_enabled_file` only. Preset `.md`
/// body management (list/create/edit/fork/delete) is kikimi.md 9章's session-window Watchers tab
/// scope, not Settings (`docs/design/26-settings-ui.md` §1/§4.4).
private struct WatchersSettingsTab: View {
    @ObservedObject private var appConfig = AppConfig.shared

    var body: some View {
        Form {
            Section("プリセットライブラリ") {
                TextField("プリセットディレクトリ", text: appConfig.binding(\.watchers.presetsDir))
                TextField("既定有効化リストファイル", text: appConfig.binding(\.watchers.defaultEnabledFile))
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - VoiceprintSpeakersTab

/// The R2 voiceprint management tab: the speaker map (`docs/design/19-voiceprint-map.md` §5) above
/// a flat list of every speaker registered in the global voiceprint database
/// (`~/.local/state/kikimi/voiceprints.json`), each with an inline rename field and an immediate
/// delete button. Rename (`docs/design/23-speaker-settings-rename.md`) is the one management
/// operation this tab supports beyond the design 13 §14 minimal scope (list + delete); merge and a
/// confirmation dialog remain out of scope -- the map and its same-person warnings stay read-only
/// aids for a future merge feature.
private struct VoiceprintSpeakersTab: View {
    @ObservedObject var viewModel: SettingsViewModel

    // Refreshed by `SettingsWindowController.show()` on every window display (not here via
    // `.task`) since this tab's view is never torn down/recreated across shows -- a `.task` here
    // would only ever fire once, for the app's entire lifetime.
    var body: some View {
        Group {
            if viewModel.voiceprintSpeakers.isEmpty {
                VStack {
                    Spacer()
                    Text("登録済みの話者はまだありません")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    // Design §5's size gate: 0–1 speakers have nothing to compare, so no map.
                    if viewModel.voiceprintMapPoints.count >= 2 {
                        Text("話者マップ（近いほど声が似ています・距離は目安）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        VoiceprintMapView(
                            points: viewModel.voiceprintMapPoints,
                            closePairs: viewModel.voiceprintClosePairs,
                            namesById: speakerNamesById,
                            selectedSpeakerId: $viewModel.selectedVoiceprintSpeakerId
                        )
                        .frame(minHeight: 140, idealHeight: 190, maxHeight: 240)
                        closeMatchBanner
                    }
                    speakerList
                }
            }
        }
        // This tab is a custom VStack/List with no insets of its own; the TabView-level `.padding()`
        // it used to rely on was removed for the grouped-form tabs (docs/design/30-settings-ui-polish.md
        // §4.5), so it pads itself.
        .padding()
    }

    private var speakerNamesById: [String: String] {
        Dictionary(
            viewModel.voiceprintSpeakers.map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// Design §5's warning banner: readable even without interpreting the map. One line per
    /// suspect pair, closest first (`voiceprintClosePairs`' order).
    @ViewBuilder
    private var closeMatchBanner: some View {
        if !viewModel.voiceprintClosePairs.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(viewModel.voiceprintClosePairs) { pair in
                    let firstName = speakerNamesById[pair.firstId] ?? pair.firstId
                    let secondName = speakerNamesById[pair.secondId] ?? pair.secondId
                    Text(
                        "⚠ \(firstName) と \(secondName) は声紋が近く、同一人物の可能性があります"
                            + "（距離 \(VoiceprintMapView.formatDistance(pair.distance))）"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }
        }
    }

    private var speakerList: some View {
        List {
            ForEach(viewModel.voiceprintSpeakers) { speaker in
                let isSelected = viewModel.selectedVoiceprintSpeakerId == speaker.id
                let neighbors: [(speaker: VoiceprintSpeaker, distance: Float, isCloseMatch: Bool)] =
                    isSelected ? viewModel.voiceprintNeighbors(of: speaker.id) : []
                VoiceprintSpeakerRow(
                    speaker: speaker,
                    isSelected: isSelected,
                    neighbors: neighbors,
                    onSelect: {
                        viewModel.selectedVoiceprintSpeakerId = isSelected ? nil : speaker.id
                    },
                    onRename: { newName in
                        Task { await viewModel.renameVoiceprintSpeaker(id: speaker.id, name: newName) }
                    },
                    onReset: {
                        Task { await viewModel.resetVoiceprintSpeaker(id: speaker.id) }
                    },
                    onDelete: {
                        Task { await viewModel.deleteVoiceprintSpeaker(id: speaker.id) }
                    }
                )
            }
        }
    }
}

/// A single row: an inline-editable name + created/updated timestamps on the left, a delete button
/// on the right. Clicking the row selects the speaker (mirrored in the map, design §5) and expands
/// its proximity list — closest voices first with true 256-d distances, ⚠ when under the
/// same-person threshold.
private struct VoiceprintSpeakerRow: View {
    let speaker: VoiceprintSpeaker
    let isSelected: Bool
    let neighbors: [(speaker: VoiceprintSpeaker, distance: Float, isCloseMatch: Bool)]
    let onSelect: () -> Void
    /// `docs/design/23-speaker-settings-rename.md` §2.1: called with the trimmed, non-empty new name.
    let onRename: (String) -> Void
    let onReset: () -> Void
    let onDelete: () -> Void

    @State private var isEditingName = false
    @State private var draftName = ""

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                nameField
                Text(
                    "作成: \(SessionListFormatting.timestamp(speaker.createdAt))　"
                        + "更新: \(SessionListFormatting.timestamp(speaker.updatedAt))"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                if speaker.embedding.isEmpty {
                    // Design 13 §4.4 "声紋リセット" / design 19 §7: an empty embedding is a normal,
                    // intentional state (post-reset or never-enrolled), not an error -- badge it so
                    // its disappearance from the map above doesn't read as broken.
                    Text("声紋未登録 — 次に手動で割り当てると再学習されます")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if isSelected, !neighbors.isEmpty {
                    Text("近い順: " + neighbors.map(Self.neighborText).joined(separator: " / "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !speaker.embedding.isEmpty {
                Button(action: onReset) {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .help("この話者の声紋をリセット（自動割り当ての対象外になり、次に手動で割り当てると再学習されます）")
            }
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("この話者を声紋データベースから削除")
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.12) : nil)
    }

    /// Toggles between a plain name label with a pencil button and an inline `TextField`, so renaming
    /// never needs a separate sheet/popover (design §2.1's "最小限"の意図を踏襲).
    @ViewBuilder
    private var nameField: some View {
        if isEditingName {
            TextField("話者名", text: $draftName, onCommit: commitRename)
                .textFieldStyle(.roundedBorder)
                .font(.body)
                .onExitCommand { isEditingName = false }
        } else {
            HStack(spacing: 4) {
                Text(speaker.name)
                    .font(.body)
                Button {
                    draftName = speaker.name
                    isEditingName = true
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("話者名を変更")
            }
        }
    }

    /// Exits edit mode unconditionally, then submits the trimmed name -- but only if it is non-empty
    /// and actually changed (`SettingsViewModel.renameVoiceprintSpeaker` itself also rejects an empty
    /// name; the "unchanged" check here just avoids a pointless store write/refresh on a no-op submit).
    private func commitRename() {
        isEditingName = false
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != speaker.name else { return }
        onRename(trimmed)
    }

    private static func neighborText(
        _ neighbor: (speaker: VoiceprintSpeaker, distance: Float, isCloseMatch: Bool)
    ) -> String {
        let warning = neighbor.isCloseMatch ? " ⚠" : ""
        return "\(neighbor.speaker.name) \(VoiceprintMapView.formatDistance(neighbor.distance))\(warning)"
    }
}
