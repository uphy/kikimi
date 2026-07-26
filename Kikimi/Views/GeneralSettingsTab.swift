import SwiftUI

/// The "一般" tab: `stt` / `diarization` / `audio` / `defaults` / `export` / `summary` (trigger fields
/// only -- `summary.model` lives in `ModelSettingsTab` alongside the other model selectors,
/// `docs/design/26-settings-ui.md` §4.2/§4.4). Split out of `SettingsView.swift` purely to keep that
/// file under the project's `file_length` lint limit (same rationale as
/// `DictationAppContextSection`'s file split).
///
/// Layout follows `docs/design/30-settings-ui-polish.md` §4.1: `.formStyle(.grouped)` (the grouped
/// form is `List`-backed and scrolls on its own, so no manual `ScrollView` wrapper is needed --
/// unlike the plain columns-style `Form` this tab used to be, which silently clipped inside the
/// NSPanel-hosted `TabView`), with tuning knobs that break recognition quality when misunderstood
/// folded into per-section `DisclosureGroup("詳細")` rows.
///
/// Every section here is a fixed set of fields. `glossary` briefly lived here too, but an unbounded
/// list among them pushed the sections below it off the window as terms accumulated; it now has its own
/// tab (`GlossarySettingsTab`, `docs/design/28-glossary.md` §4).
struct GeneralSettingsTab: View {
    @ObservedObject private var appConfig = AppConfig.shared

    var body: some View {
        Form {
            Section("音声認識 (STT)") {
                TextField(
                    "言語コード", text: appConfig.binding(\.stt.language),
                    prompt: Text("ja-JP / auto")
                )
                DisclosureGroup("詳細") {
                    Picker("チャンク長", selection: appConfig.binding(\.stt.chunkMs)) {
                        // `String($0)` deliberately skips `Text`'s locale-aware Int interpolation:
                        // "2,240 ms" with a grouping separator reads wrong for a millisecond value.
                        ForEach(SttEngineConfig.validChunkMsTiers.sorted(), id: \.self) {
                            Text("\(String($0)) ms").tag($0)
                        }
                    }
                    SettingsDoubleField(
                        label: "セグメント確定タイムアウト", unit: "秒",
                        value: appConfig.binding(\.stt.segmentIdleTimeout),
                        range: 0.5...10.0, step: 0.5
                    )
                    SettingsIntField(
                        label: "セグメント文字数上限", unit: "文字",
                        value: appConfig.binding(\.stt.maxSegmentCharacters),
                        range: 20...400, step: 10
                    )
                    Toggle("高精度再認識（二段デコード）", isOn: appConfig.binding(\.stt.twoPassDecode))
                        .help(
                            "セグメント確定時に該当区間を高精度モデルで再認識します（進行中の表示は従来どおり）。"
                                + "初回はモデルのダウンロードが入ります。オフにすると次の録音から無効になります"
                        )
                }
            }
            Section("話者分離") {
                Toggle("話者分離を有効にする", isOn: appConfig.binding(\.diarization.enabled))
                if appConfig.data.diarization.enabled {
                    TextField("自分の表示名", text: appConfig.binding(\.diarization.selfName))
                    DisclosureGroup("詳細") {
                        Picker("LS-EEND ステップ幅", selection: appConfig.binding(\.diarization.stepMs)) {
                            Text("100 ms").tag(100)
                            Text("500 ms").tag(500)
                        }
                        Picker("モデルバリアント", selection: appConfig.binding(\.diarization.variant)) {
                            ForEach(["callhome", "dihard3", "dihard2", "ami"], id: \.self) { Text($0).tag($0) }
                        }
                        SettingsDoubleField(
                            label: "同一人物判定の距離閾値",
                            value: appConfig.binding(\.diarization.speakerMatchThreshold),
                            range: 0.0...1.0, step: 0.01, fractionDigits: 2
                        )
                        SettingsDoubleField(
                            label: "判定マージン",
                            value: appConfig.binding(\.diarization.speakerMatchMargin),
                            range: 0.0...0.5, step: 0.01, fractionDigits: 2
                        )
                    }
                }
            }
            Section("音声") {
                Toggle(
                    "内蔵スピーカー利用時にヘッドホンを提案する",
                    isOn: appConfig.binding(\.audio.suggestHeadphonesOnBuiltInSpeaker)
                )
            }
            Section("既定テンプレート") {
                TextField("既定 context.md のパス", text: appConfig.binding(\.defaults.contextFile))
                TextField("既定 summary_template.md のパス", text: appConfig.binding(\.defaults.summaryTemplateFile))
            }
            Section("サマリ更新") {
                SettingsIntField(
                    label: "更新トリガ（セグメント数）", unit: "セグメント",
                    value: appConfig.binding(\.summary.updateTriggerSegments),
                    range: 5...100, step: 5
                )
                SettingsIntField(
                    label: "更新トリガ（経過時間）", unit: "秒",
                    value: appConfig.binding(\.summary.updateTriggerSeconds),
                    range: 30...600, step: 30
                )
                Toggle("タイトル自動命名", isOn: appConfig.binding(\.summary.autoNaming))
            }
            Section("Wiki Export") {
                Toggle("セッション終了時に自動 export する", isOn: appConfig.binding(\.export.enabled))
                if appConfig.data.export.enabled {
                    TextField("Export 先ディレクトリ", text: appConfig.binding(\.export.targetDir))
                }
            }
        }
        .formStyle(.grouped)
    }
}
