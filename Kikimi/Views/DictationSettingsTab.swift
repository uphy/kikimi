import AppKit
import KeyboardShortcuts
import SwiftUI

// MARK: - DictationSettingsTab

/// The "入力" tab: `dictation.enabled`, the hotkey `Recorder`, the `insert_method` picker, an
/// accessibility-permission hint, D2's `refine`/`model` fields (`docs/design/25-dictation-mode.md`
/// §6), and the `history` section (`docs/design/29-dictation-history.md` §7.2).
///
/// Binds directly to `AppConfig.shared` (an `ObservableObject`) rather than going through
/// `SettingsViewModel`, since every value here is a straight `config.yaml` read/write with no
/// derived state -- unlike the 話者 tab's `VoiceprintStore`-backed map/proximity computations.
///
/// Split out of `SettingsView.swift` (which holds every other tab) once the 履歴 section pushed
/// that file past SwiftLint's 600-line file-length limit -- the same reason `GlossarySettingsTab`
/// already lives in its own file.
struct DictationSettingsTab: View {
    @ObservedObject private var appConfig = AppConfig.shared
    @ObservedObject private var dictationController = DictationController.shared

    /// Re-enumerated in `.onAppear` (mirrors `AudioInputPopoverContent`'s `.onAppear { viewModel
    /// .refreshAudioInputs() }`, `docs/design/10-audio-input-selection.md` section 2/7.2): every
    /// call reads current system state, no caching, so a device plugged in while Settings is open
    /// only shows up once this tab reappears.
    @State private var availableMicDevices: [AudioDeviceInfo] = []
    private let audioInputEnumerator: any AudioInputEnumerating = AudioInputEnumerator()

    /// Non-nil while the "履歴をすべて削除" confirmation dialog is up.
    @State private var isPendingDeleteAllHistory = false
    /// Non-nil while an alert reports a `DictationHistoryStore.deleteAll()` failure. Per design
    /// §7.2, only `deleteAll()`'s failure surfaces an alert -- there is no success toast.
    @State private var deleteAllHistoryErrorMessage: String?

    var body: some View {
        // `.formStyle(.grouped)` (docs/design/30-settings-ui-polish.md §4.4): the grouped form is
        // `List`-backed and scrolls on its own, so the manual `ScrollView` wrapper the old
        // columns-style `Form` needed (it silently clipped inside this NSPanel-hosted `TabView`,
        // leaving the アプリ別コンテキスト section's tail unreachable) is gone.
        Form {
            Toggle("ディクテーションを有効にする", isOn: enabledBinding)

            if appConfig.data.dictation.enabled {
                KeyboardShortcuts.Recorder("ホットキー:", name: .dictate)

                Picker("挿入方式", selection: insertMethodBinding) {
                    Text("クリップボード（既定）").tag(DictationInsertMethod.pasteboard)
                    Text("Unicode直接入力").tag(DictationInsertMethod.unicode)
                }

                micDevicePicker

                // design 31 §4: a sibling of the history section below (inside the `enabled`
                // block, independent of `refine`). Applies at runtime via `DictationController`'s
                // `(enabled, twoPassDecode)` config subscription -- no restart needed.
                Toggle("発話全体を高精度モデルで再認識する", isOn: twoPassDecodeBinding)
                    .help("発話終了後に発話全体を高精度モデルで再認識して確定します（ライブ表示は従来どおり）。オフにするとモデルのメモリを解放します")

                if appConfig.data.dictation.twoPassDecode {
                    // Its own picker rather than following `stt.batch_model`: the latency budgets
                    // differ. A meeting absorbs an extra second per confirmed window; here it is
                    // the wait between releasing the key and the text appearing.
                    Picker("再認識モデル", selection: batchModelBinding) {
                        Text("Parakeet 日本語（高速・既定）").tag(SttConfig.parakeetBatchModel)
                        Text("Qwen3-ASR 0.6B").tag(Qwen3Variant.small.rawValue)
                        Text("Qwen3-ASR 1.7B（高精度）").tag(Qwen3Variant.large.rawValue)
                    }
                    .help(
                        "Qwen3 は語の取りこぼしが少なく英語の固有名詞も原語で出しますが、"
                            + "キーを離してから挿入されるまでが 10 秒の発話で 0.1〜0.5 秒ほど延びます。"
                            + "モデルのダウンロードは一般タブから行えます"
                    )
                }

                if !dictationController.isAccessibilityTrusted {
                    accessibilityHint
                }

                Toggle("LLMで整形する", isOn: refineBinding)
                    .help("フィラー除去・句読点補完をしてから挿入します（約1秒の待ち時間が発生します）")

                if appConfig.data.dictation.refine {
                    TextField("モデル", text: modelBinding, prompt: Text("空欄で既定値"))

                    DictationAppContextSection()
                }

                // design 29 §7.2: deliberately a sibling of the `refine` block above, placed
                // right after it closes, rather than nested inside it. History records every
                // utterance regardless of `refine` (DH12), so nesting it under `refine` would
                // hide these controls whenever refine is off -- contradicting that invariant.
                historySection
            }
        }
        .formStyle(.grouped)
        .onAppear { availableMicDevices = audioInputEnumerator.inputDevices() }
        .confirmationDialog(
            "履歴をすべて削除しますか？",
            isPresented: $isPendingDeleteAllHistory,
            titleVisibility: .visible
        ) {
            Button("削除", role: .destructive) { deleteAllHistory() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("保存されている音声・テキスト・整形結果がすべて削除されます。この操作は取り消せません。")
        }
        .alert(
            "履歴の削除に失敗しました",
            isPresented: Binding(
                get: { deleteAllHistoryErrorMessage != nil },
                set: { isPresented in if !isPresented { deleteAllHistoryErrorMessage = nil } }
            )
        ) {
            Button("OK") { deleteAllHistoryErrorMessage = nil }
        } message: {
            Text(deleteAllHistoryErrorMessage ?? "")
        }
    }

    /// The "マイク" `Picker` (`docs/design/25-dictation-mode.md` §6, `docs/design/29-dictation-history.md`
    /// §3.2 addendum): "システムデフォルト" + the current `AudioInputEnumerator.inputDevices()` list,
    /// reusing the meeting side's `AudioInputPopoverContent.micSection` shape (same `Picker`, same
    /// `nil`/empty-means-default row). Unlike that popover, this binds directly to
    /// `dictation.mic_device_uid` (a plain non-optional `String`, not `AudioInputSelection.Mic
    /// .deviceUid: String?`), so the "システムデフォルト" row tags `""` instead of `String?.none`.
    @ViewBuilder
    private var micDevicePicker: some View {
        Picker("マイク", selection: micDeviceUIDBinding) {
            Text("システムデフォルト").tag("")

            // design 10 §5.1/§7.2's "見つからない選択を保持したまま表示" convention: a persisted UID
            // that the current enumeration no longer reports (unplugged device, or just moved to
            // another Mac's config.yaml) stays visible and selected rather than being silently
            // reset -- `MicrophoneSource` itself already degrades this case to the system default
            // input device at capture time, so config.yaml is deliberately left untouched here.
            if let staleUID = staleMicDeviceUID {
                Text("\(staleUID)（見つかりません）").tag(staleUID)
            }

            ForEach(availableMicDevices) { device in
                Text(device.name).tag(device.uid)
            }
        }
    }

    /// The currently-configured `mic_device_uid` when it is non-empty but absent from
    /// `availableMicDevices` (see `micDevicePicker`'s doc comment). `nil` (including the empty
    /// "システムデフォルト" selection) never counts as stale.
    private var staleMicDeviceUID: String? {
        let uid = appConfig.data.dictation.micDeviceUID
        guard !uid.isEmpty, !availableMicDevices.contains(where: { $0.uid == uid }) else { return nil }
        return uid
    }

    /// The "履歴" section (`docs/design/29-dictation-history.md` §7.2): `history.enabled` + its
    /// privacy disclosure (DH1), the max-retained-entries field, and open/delete-all actions for
    /// `DictationHistoryStore` (`~/.local/state/kikimi/dictation/history/`).
    @ViewBuilder
    private var historySection: some View {
        Section("履歴") {
            Toggle("発話履歴を保存する", isOn: historyEnabledBinding)
                .help("発話ごとの音声・テキスト・整形結果をローカルに保存し、履歴ウィンドウで確認できます。内容は平文で保存されます")

            if appConfig.data.dictation.history.enabled {
                TextField("最大保持数", text: historyMaxEntriesBinding)
            }

            HStack {
                Button("履歴を開く") {
                    WindowManager.shared.showDictationHistory()
                }
                Button("履歴をすべて削除") {
                    isPendingDeleteAllHistory = true
                }
            }
        }
    }

    private func deleteAllHistory() {
        Task {
            do {
                try await DictationHistoryStore.shared.deleteAll()
            } catch {
                deleteAllHistoryErrorMessage = String(describing: error)
            }
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { appConfig.data.dictation.enabled },
            set: { newValue in appConfig.update { $0.dictation.enabled = newValue } }
        )
    }

    private var insertMethodBinding: Binding<DictationInsertMethod> {
        Binding(
            get: { appConfig.data.dictation.insertMethod },
            set: { newValue in appConfig.update { $0.dictation.insertMethod = newValue } }
        )
    }

    private var micDeviceUIDBinding: Binding<String> {
        Binding(
            get: { appConfig.data.dictation.micDeviceUID },
            set: { newValue in appConfig.update { $0.dictation.micDeviceUID = newValue } }
        )
    }

    private var twoPassDecodeBinding: Binding<Bool> {
        Binding(
            get: { appConfig.data.dictation.twoPassDecode },
            set: { newValue in appConfig.update { $0.dictation.twoPassDecode = newValue } }
        )
    }

    private var batchModelBinding: Binding<String> {
        Binding(
            get: { appConfig.data.dictation.batchModel },
            set: { newValue in appConfig.update { $0.dictation.batchModel = newValue } }
        )
    }

    private var refineBinding: Binding<Bool> {
        Binding(
            get: { appConfig.data.dictation.refine },
            set: { newValue in appConfig.update { $0.dictation.refine = newValue } }
        )
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { appConfig.data.dictation.model },
            set: { newValue in appConfig.update { $0.dictation.model = newValue } }
        )
    }

    private var historyEnabledBinding: Binding<Bool> {
        Binding(
            get: { appConfig.data.dictation.history.enabled },
            set: { newValue in appConfig.update { $0.dictation.history.enabled = newValue } }
        )
    }

    /// A `TextField` needs a `String` binding, but `maxEntries` is a non-optional `Int`
    /// (`DictationConfig.swift:125`). Mirrors `AppConfig.optionalStringBinding`'s round-trip
    /// convention: an unparsable or non-positive draft is simply not written back (the field keeps
    /// showing the last valid value until the user types a valid one), rather than clamping or
    /// crashing -- config decode already normalizes an invalid persisted value on load
    /// (`DictationConfig.swift:144-169`), so this binding only needs to guard the write path.
    private var historyMaxEntriesBinding: Binding<String> {
        Binding(
            get: { String(appConfig.data.dictation.history.maxEntries) },
            set: { newValue in
                guard let intValue = Int(newValue), intValue >= 1 else { return }
                appConfig.update { $0.dictation.history.maxEntries = intValue }
            }
        )
    }

    private var accessibilityHint: some View {
        HStack {
            Text("アクセシビリティ権限が必要です")
                .foregroundStyle(.orange)
            Spacer()
            Button("システム設定を開く") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}
