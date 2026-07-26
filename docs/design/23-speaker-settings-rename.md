# 23. Settings 話者リネームの過去会議への反映

`docs/design/13-speaker-diarization.md` 14章で将来検討として保留されていた「Settings の話者タブに
リネームを追加する」の詳細設計。単なるUI追加ではなく、**改名が過去に終了した会議の書き起こし表示にも
反映される**ことを要件とする。

参照元: `docs/design/13-speaker-diarization.md`（4.3〜4.4節・6.1節）, `docs/design/19-voiceprint-map.md`
（Settings 話者タブ）, `docs/design/20-voiceprint-misassignment-mitigation.md`（displayName/
globalSpeakerId の既存の意味論）。

## 1. 現状（前提となる既存実装）

- `VoiceprintSpeaker`（`Kikimi/Diarization/VoiceprintStore.swift`）は最初から `id`（UUID・不変）と
  `name`（表示名・可変）を分離して持つ。`VoiceprintStore.renameSpeaker(id:name:)` も既に実装済み
  （現状の呼び出し元は会議内のリネームフローのみ）
- 会議内リネーム（`MeetingWorkspaceViewModel+Rename.swift` の `applyRename`/`renameSlot`）は
  `speaker_assignments.json` の各 slot に `globalSpeakerId`（`VoiceprintSpeaker.id`）と、その時点の
  名前を `displayName` としてスナップショット保存する。`SpeakerAssignments.applyRename` は同じ
  `globalSpeakerId` を持つ全 slot に同時反映するが、これは**同一会議内**に限られる
- 表示側（`SpeakerLabelResolver.resolvedLabel(forSlot:assignments:)`、
  `Kikimi/ViewModels/SpeakerLabeling.swift`）は `assignments.assignments[slot].displayName` を
  そのまま使う。`globalSpeakerId` を都度 `voiceprints.json` に問い合わせて最新名を取得する仕組みはない
- Settings の話者タブ（`SettingsView.swift` の `VoiceprintSpeakersTab`）は一覧・声紋リセット・削除の
  みで、リネームUIが無い（design 13 §14 で意図的に見送り）

### 1.1 ギャップ

Settings でグローバルに改名しても、過去に終了した会議を開き直したときの書き起こし表示は
`speaker_assignments.json` に焼き込まれた古い `displayName` のままになる。IDと表示名の分離自体は
既にあるが、**表示が ID 経由で動的に解決されていない**ことが本質的なボトルネック。

## 2. 設計

### 2.1 Settings リネームUI

- `SettingsViewModel` に `renameVoiceprintSpeaker(id: String, name: String) async` を追加する。
  `SpeakerName.trimmed(_:)`（既存の共通正規化ユーティリティ）で trim し、空文字なら何もしない。
  `voiceprintStore.renameSpeaker(id:name:)` → `refreshVoiceprintSpeakers()` の順で呼ぶ
  （他の `delete`/`resetVoiceprintSpeaker` と同じ best-effort パターン: 失敗は warning ログのみ）
- `VoiceprintSpeakerRow`（`SettingsView.swift`）に編集導線を追加する。名前ラベルをクリックすると
  `TextField` に切り替わり、Enter/フォーカスアウトで確定する形を想定（既存の削除ボタンと並ぶ
  borderless ボタンでも良い）
- 重複名チェックはしない（同名の複数話者登録は design 20 §4 で既に許容されている前提を踏襲する）
- `SettingsView.swift` 冒頭の「no rename」という趣旨のドキュメントコメントを、実態に合わせて更新する

### 2.2 表示解決の動的化（本質）

`SpeakerLabelResolver.resolve(...)` に `speakerNames: [String: String]`
（`globalSpeakerId -> 現在の登録名`）パラメータを追加する。

- slot / segment override が `globalSpeakerId` を持つ場合、`speakerNames[globalSpeakerId]` が
  あればそれを優先して `.named(...)` にする
- `speakerNames` に見つからない場合（対象話者が削除済み）は、従来どおりスナップショットの
  `displayName` にフォールバックする（**削除前の最後の名前を表示し続ける** — 過去ログの可読性を
  優先し、削除の瞬間に「Speaker N」へ退行させない）
- `globalSpeakerId` が `nil` の slot / override（ローカルオンリーリネーム・同名重複での曖昧解決など、
  design 20 §4/§5.4 の `.localOnly`/`.ambiguous` 系）は対象外。従来どおりスナップショットの
  `displayName` をそのまま使う（そもそもグローバル登録に紐付いていないので解決しようがない）

呼び出し側 `MeetingWorkspaceViewModel+Diarization.swift` の `recomputeSpeakerLabels()` で、既存の
`knownVoiceprintSpeakers`（`onAppear()` 時に `refreshKnownVoiceprintSpeakers()` で最新化済み）から
`[id: name]` の辞書を組み立てて渡す。追加の I/O は発生しない。

### 2.3 反映タイミング

- セッションウィンドウを開き直すたびに最新のグローバル名で解決されれば要件を満たす、という前提で
  設計する（`onAppear()` は既に `refreshKnownVoiceprintSpeakers()` → `initializeSpeakerLabelsFromBackfill()`
  の順で呼ばれている）
- Settings でのリネームを他ウィンドウへリアルタイム配信する仕組み（`NotificationCenter` 等)は
  **今回は作らない**。開いたままの会議ウィンドウは、次に何らかのトリガ（grace ticker・新規 turn・
  リネーム操作など）で `recomputeSpeakerLabels()` が呼ばれるまで古い表示のままになり得るが、許容する
  （必要になれば将来追加する）

### 2.4 スコープ外（明示）

- **Wiki export**（`WikiExportRenderer`）: 現状 `mic`/`system` の物理ソースラベルのみで、実名解決
  自体が未実装（design 13 §6.3 の既知ギャップ、今回の変更より前から存在）。今回は触らない
- **サマリの `participants` / `action_items.assignee`**: LLM が生成する自由記述文字列で
  `globalSpeakerId` に紐付いていないため、改名に追随しない
- **削除話者のカスケード整理**: 既存方針どおり、`globalSpeakerId` の宙ぶらりん参照はそのまま許容する
  （`VoiceprintStore.deleteSpeaker` の既存ドキュメントコメントのとおり）

## 3. 実装対象ファイル

| ファイル | 変更内容 |
|---|---|
| `Kikimi/ViewModels/SettingsViewModel.swift` | `renameVoiceprintSpeaker(id:name:)` 追加 |
| `Kikimi/Views/SettingsView.swift` | `VoiceprintSpeakerRow` に編集UI追加。ドキュメントコメント更新 |
| `Kikimi/ViewModels/SpeakerLabeling.swift` | `SpeakerLabelResolver.resolve`/`resolvedLabel`/`displayString` に `speakerNames` パラメータ追加 |
| `Kikimi/ViewModels/MeetingWorkspaceViewModel+Diarization.swift` | `recomputeSpeakerLabels()` で `speakerNames` 辞書を構築して渡す |
| `docs/design/13-speaker-diarization.md` | 14章の「リネームは将来検討」の記述を本設計へのリンクに更新 |

## 4. テスト

- `SpeakerLabelingTests.swift`: `speakerNames` によるオーバーライド（`globalSpeakerId` 一致時に
  スナップショットより優先されること）、未登録IDのフォールバック、`globalSpeakerId` が `nil` の
  ときは無視されること
- `SettingsViewModelTests.swift`: `renameVoiceprintSpeaker` が trim・空文字拒否・`voiceprintStore`
  呼び出し・リフレッシュを行うこと
- `MeetingWorkspaceViewModelTests.swift`: 過去会議相当の fixture（`globalSpeakerId` 付き slot）を
  `knownVoiceprintSpeakers` の名前と食い違わせた状態で `recomputeSpeakerLabels()` した際に新しい
  名前が採用されること
- kikimi-verify（手動）: Settings で改名 → 別セッション（Ended）を開き直して書き起こしの表示名が
  更新されていることを確認

## 5. 未解決事項として明記した判断（ユーザー確認済み）

- リアルタイム配信は今回スコープ外。「開き直したときに反映される」のみを満たす
- 削除済み話者は `speakerNames` に見つからない場合、スナップショットの最後の名前を表示し続ける
