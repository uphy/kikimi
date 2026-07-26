# 20. 声紋誤マッチ対策（オープンセット照合の強化と訂正フィードバック）

対象読者: Kikimi 実装者（Claude Code 自身）。実装前に必ず読むこと。

> **追記（実測後の方針変更）**: 本設計時点では「M3: 不信任 auto slot の EMA 除外」により
> `assigned_by: "auto"` のまま Ended を迎えた slot も（disputed でなければ）声紋更新の対象に
> していたが、「ユーザーの明示的なフィードバック以外では声紋を更新してほしくない」という要件により、
> **`.auto` slot は disputed 判定に関わらず声紋更新の候補から完全に除外**するよう変更した
> （`.user` slot と segment override 集約のみが対象）。以降の記述にある「不信任でない `.auto`
> slot への EMA 適用」は現在の実装には存在しない（`docs/design/13-speaker-diarization.md` 4.4節が
> 最新の挙動）。`DisputedSlotDetector` 自体は型・テストとも残っているが、この EMA フォールバック
> 経路の呼び出しは削除済み。

> **追記（2026-07-07・`DisputedSlotDetector` の再利用）**: 上で「呼び出しは削除済み」とした
> `DisputedSlotDetector` に、新しい役割「不信任 slot の再照合リセット」を与えた（§6.4）。
> 症状: クリーンな 1 人だけの slot が誤った既存話者に auto 実名化されると、ユーザーが「この発言だけ」で
> 何度訂正しても収束しない。override はその 1 行の表示しか直さず（slot の `.auto` は不変）、
> closed-set rematch は実名済み slot を巻き戻さない（design 22 §3）ため、同じ slot に入る新しい
> セグメントが誤名を出し続ける。対策として、override が矛盾させた `.single`/`.auto` slot を
> `DisputedSlotDetector` で検出して匿名へリセットし、訂正済み名簿（closed-set）で再照合する。

参照元: `docs/design/13-speaker-diarization.md`（話者分離の基本設計。特に 4.3〜4.4 節・5 節・6.1 節・8 章）,
`docs/design/19-voiceprint-map.md`（Settings 話者タブ）, `kikimi.md` 8.5 章（best-effort 原則）。

本設計の要点は以下のとおり。

- **解決したい問題**: 未登録の新しい話者が話すと、既存の登録話者に auto 割り当てされることが非常に多い。
  さらにユーザーが「この発言だけ」（`segment_overrides`）で訂正しても声紋学習に一切つながらず、
  slot の auto 割り当ても残るため、誤った既存話者の声紋が Ended 時 EMA（α = 0.1）で
  **新しい話者の声に汚染され続け**、セッションを重ねるほど誤マッチが強化される悪循環に入っている
- **M1: マージン付きオープンセット照合と距離ログ** — `findBestMatch` の「絶対閾値 + 最近傍」に
  「2 位との距離差（マージン）」判定を加え、曖昧なマッチを棄却する。マッチ成功・棄却の全ケースで
  最近傍距離を info ログに残し、閾値チューニングを実測ベースにする（13 章 §15 が Phase 4 前に
  求めていた失敗時距離ログを成功時込みで前倒し実装する）
- **M2: 「この発言だけ」の学習フィードバック** — segment override に既存話者ピッカーを追加し、
  `global_speaker_id` を保持できるようにする。Ended 時に override 済みセグメントの音声を
  `diarization.jsonl` の turn と交差させて WAV から切り出し、既存話者なら EMA（α = 0.3）、
  新規名なら新規登録する。「この発言だけ」が誤マッチ訂正の実質的な主経路になっている現状を、
  設計 13 章 §14 の「セグメント単位声紋分類の教師データ」構想の軽量版として今すぐ学習に接続する
- **M3: 不信任 auto slot の EMA 除外** — auto 割り当てされた slot のセグメントに、slot の表示名と
  異なる名前の override が付いたら、その slot を「不信任（disputed）」として Ended 時 EMA の
  候補から除外する。これが汚染ループを止める止血弁。加えてリネームポップオーバーに
  「すべての発言に適用が学習される正しい経路」であることのヒントを出す
- **名前の正規化（重複登録の解消）** — フリーテキスト入力の名前が既知話者名と完全一致した場合、
  新規登録ではなく既存話者への割り当てとして扱う正規化を slot リネーム・segment override の
  両経路に共通で入れる（現状 slot 経路は同名の重複 speaker を登録してしまう）
- **既定閾値（0.65）は据え置く** — 誤マッチ多発の主因は「新規話者に対する開集合棄却の欠如 +
  汚染ループ」であり、M1 のログで実測分布を取ってから閾値既定値の変更を判断する（15 章）。
  汚染済み DB の修復は既存の「声紋リセット」（13 章 4.4 節）をそのまま使う（本設計での変更なし）

## 1. 背景 — 問題の構造

現行実装（R2）で誤マッチが定着するメカニズムは 3 層ある。

| 層 | 現状 | 帰結 |
|---|---|---|
| 照合 | `VoiceprintStore.findBestMatch` は「cosine 距離 < 0.65 の最近傍」のみ。新規話者（DB に本人がいない）を棄却する仕組みがない | 圧縮音声で embedding がブレると既存の誰かが偶然閾値を切り、新規話者が auto 割り当てされる |
| 訂正 | 「この発言だけ」（`segment_overrides`）は表示レイヤ専用。声紋登録も slot の `assigned_by` 変更もしない | 訂正が学習に反映されず、次のセッションでも同じ誤マッチが起きる |
| 学習 | override で訂正しても slot は `.auto` のまま Ended を迎え、「訂正されなかった = 正しかった」とみなす EMA（α = 0.1）が走る | **誤マッチ先の既存話者の声紋が新規話者の声に寄っていき**、誤マッチが強化される |

正しい訂正経路（「すべての発言に適用」+ 新規名 → 声紋登録）は存在するが、slot に複数人の発言が
混ざるケースでは per-segment 訂正しか選べず、その経路が学習につながらないのが構造的な穴。

## 2. 対策の全体像

| ID | 対策 | 効く場所 |
|---|---|---|
| M1 | マージン付き照合 + 距離ログ | 誤マッチの発生そのものを減らす。閾値調整の実測材料を得る |
| M2 | segment override の学習フィードバック（ピッカー + Ended 時 enrollment） | 訂正を次セッション以降の自動認識に反映する |
| M3 | 不信任 auto slot の EMA 除外 + ポップオーバーのヒント | 声紋汚染ループを止める |
| 共通 | フリーテキスト名の既知話者への正規化 | 同名重複登録を防ぎ、名前一致の訂正を EMA に接続する |

3 層それぞれに 1 つずつ対応する。どれか単独では不十分（M1 だけでは既に汚染された DB を救えない、
M2 だけでは汚染が続く、M3 だけでは訂正が学習されない）。

## 3. M1: マージン付き照合と距離ログ

### 3.1 照合の意味論

現行の `findBestMatch(embedding:threshold:)` を、**候補列挙 + 純関数の受理判定**に分離する。

- `VoiceprintStore.findMatchCandidate(embedding:) -> VoiceprintMatchCandidate?`（actor 内・新設）:
  閾値と無関係に、全 speaker との距離から最近傍と次点を返す。**次点（runnerUp）は
  「最近傍と trimmed 名が異なる speaker のうち最近傍」から取る** — 同名の speaker は
  どちらにマッチしても同一人物なので、曖昧性（マージン競合）として扱わない

  ```swift
  struct VoiceprintMatchCandidate: Sendable, Equatable {
      let speaker: VoiceprintSpeaker
      let distance: Float
      /// 最近傍と trimmed 名が異なる speaker のうち最近傍との距離。
      /// 異なる名前の speaker が登録されていなければ nil。
      let runnerUpDistance: Float?
      let runnerUpName: String?   // ログ用
  }
  ```

  マージンの意図は「**別人**との混同の検出」であり、この次点定義がその意味論と一致する。
  同名を除外しないと、既存 DB に同一人物の重複エントリがある場合（§4 が認めるとおり、
  現状の slot 経路は同名の重複 speaker を登録してしまう）に重複同士の距離差が常に小さく、
  本人の照合が毎回 `rejectedByMargin` になって、これまで auto 実名化できていた話者が
  恒常的に匿名へ退行する（本設計の目的と逆行する）

- `VoiceprintMatchPolicy.decide(candidate:threshold:margin:) -> VoiceprintMatchDecision`（pure・新設。
  `Kikimi/Diarization/VoiceprintMatchPolicy.swift`）:

  ```swift
  enum VoiceprintMatchDecision: Equatable {
      case accepted
      case rejectedByThreshold      // distance >= threshold
      case rejectedByMargin         // runnerUp - distance < margin（曖昧）
  }
  ```

  受理条件: `distance < threshold` **かつ**（`runnerUpDistance == nil` または
  `runnerUpDistance - distance >= margin`）。

- 既存の `findBestMatch(embedding:threshold:)` は削除し、呼び出し側
  （`RealtimeDiarizationCoordinator+Voiceprint.swift` の `extractAndMatchVoiceprint`）を
  `findMatchCandidate` + `VoiceprintMatchPolicy` に置き換える。他に呼び出し元はない
  （`KnownSpeakerSort` は距離ソートのみで `findBestMatch` を使っていない）

### 3.2 マージン判定の限界の明示

マージンは**異なる名前の speaker が 2 人以上登録されているときにしか効かない**
（1 人だけ、または全員同名なら次点が存在しない）。単独登録での新規話者誤マッチは閾値と
M2/M3 の学習・止血で対処する。声紋リセット済み speaker（`embedding: []` → 距離 `.infinity`）は
最近傍にも次点にもなり得ない（`.infinity` は `runnerUpDistance` の計算から除外する。
`.infinity - distance >= margin` は常に真なので数学的には入れても無害だが、ログに `inf` が
出るのは紛らわしいため明示的に除く）。

**既存の同名重複エントリの扱い**: 次点を異名 speaker に限定する（3.1 節）ことで、既存 DB に
残る同名重複はマージン棄却の原因にならない。ただし重複エントリ自体は残り続ける
（4 章の名前正規化は今後の重複を防ぐだけで既存分は救わず、声紋リセットも重複エントリを
統合しない）。重複の整理方法は §12 の Open Question とする。

### 3.3 距離ログ

`extractAndMatchVoiceprint` で判定結果を必ず 1 行ログする（サブシステム
`io.github.uphy.Kikimi`、カテゴリは coordinator 既存のもの）。

| ケース | レベル | 内容 |
|---|---|---|
| accepted | info | slot / マッチ名 / distance / runner-up 名と距離 / threshold / margin |
| rejectedByThreshold | info | slot / 最近傍名 / distance / threshold（13 章 §15 の「auto マッチ失敗時の距離ログ」に相当） |
| rejectedByMargin | info | slot / 最近傍名と距離 / 次点名と距離 / margin |
| DB 空 | debug | 従来どおり |

名前はローカル個人アプリなので `privacy: .public` でよい（既存ログと同じ扱い）。

### 3.4 config

```yaml
diarization:
  speaker_match_threshold: 0.45   # 実測データにより 0.65 から引き下げ（447 行目の課題に対応）
  speaker_match_margin: 0.05      # 新設。0 でマージン判定を無効化（従来挙動）
```

- `AppConfig` の `DiarizationConfig` に `speakerMatchMargin: Double`（既定 0.05、防御的 decode。
  **負値は 0 にクランプ**する — 実質「マージン無効」と等価だが仕様として明示しテスト可能にする）を追加
- `RealtimeDiarizationCoordinator` の init に `speakerMatchMargin` を追加し、
  `defaultDiarizationCoordinatorFactory` で配線する

## 4. 共通: フリーテキスト名の既知話者への正規化

slot リネーム・segment override の両方で使う前段の正規化。

- `NormalizedRenameTarget.resolve(name:knownSpeakers:) -> NormalizedRenameTarget`（pure・新設）。
  `.newName(name)` の trimmed 名を既知話者の `name`（trimmed）と突き合わせて 3 値に解決する:

  | 一致数 | 結果 | 各経路の挙動 |
  |---|---|---|
  | 1 人 | `.existing(globalSpeakerId:name:)` | `.existingSpeaker` と同じ扱い（割り当て + Ended 時 EMA 対象） |
  | 0 人 | `.new(name)` | 従来どおり新規登録経路 |
  | 複数人（同名重複 DB） | `.ambiguous(name)` | **登録も EMA も抑止**。slot 経路は `.localOnly` 相当（セッションローカル表示名のみ）、override 経路は表示名保存のみで学習スキップ（info ログ）。どの重複が本人か機械では決められないため、重複を増やしも誤って混ぜもしない |

- 適用箇所: `applyRename(slot:submission:)` の冒頭、および M2 の override 送信処理の冒頭
- 効果:
  - 現状 slot 経路の「既知話者と同じ名前をタイプすると重複 speaker を登録してしまう」穴が塞がる
  - override で「田中さん」とタイプした訂正が、既存の田中さんへの EMA サンプルとして扱える
  - M2 の write-back（5.4 節）が失敗しても、次の Ended で名前一致から同一 speaker に解決されるため
    重複登録に対して自己修復的になる
- **トレードオフ（受容する）**: 実在の同姓同名の**別人**を意図してタイプした場合も無警告で既存話者に
  割り当てられ、α = 0.3 の EMA でその声紋に混入する（本設計が解こうとしている汚染と同型の副作用）。
  ローカル個人アプリの会議参加者で完全同名の別人は稀なので受容し、区別したい場合は
  「田中さん（営業）」のように識別子付きの名前を使う運用でエスケープする

## 5. M2: segment override の学習フィードバック

### 5.1 データモデル

`SegmentSpeakerOverride`（`speaker_assignments.json` の `segment_overrides` 値）に
`global_speaker_id` を追加する。

```json
{
  "segment_overrides": {
    "seg_00042": { "display_name": "佐藤さん", "global_speaker_id": "b3f1..." }
  }
}
```

- `globalSpeakerId: String?`。既知話者ピッカーで選んだ場合と、正規化（4 章）で既存話者に解決した
  場合、および Ended 時 enrollment の write-back（5.4 節）でセットされる
- 旧ファイル互換: optional の synthesized decode で欠落キーは自然に `nil` になる
  （`SessionJSONCoding` の snake_case キー戦略で `global_speaker_id` は自動対応）。
  `SpeakerAssignments` のようなカスタム `init(from:)` は**不要** — 過剰実装しない
- `diarization.jsonl` / `transcript.jsonl` は**一切変更しない**（13 章 4.1 節の不変条件を維持）

### 5.2 UI（リネームポップオーバー）

`SegmentOverrideFieldView` に slot 行と同じ既知話者ピッカー（`Menu`）を追加する。

- ピッカー選択 → `.existingSpeaker` として送信。フリーテキスト → `.newName` として送信し、
  ViewModel 側で正規化（4 章）
- コールバック型を `onSubmitSegment: (_ submission: SpeakerRenameSubmission?) -> Void` に変更
  （`nil` = 解除。従来の `displayName: String?` から置き換え）
- `overrideSegmentSpeaker(segmentId:displayName:)` は
  `overrideSegmentSpeaker(segmentId:submission:)` に改め、`displayName` + `globalSpeakerId` を保存する
- ピッカーの並び順は slot 行と同じ `KnownSpeakerSort`。ただしセグメント単独の embedding は
  持っていないため、当該行の primary slot の embedding（あれば）で並べ、なければ
  `KnownSpeakerSort` の既存挙動どおり `updatedAt` 降順
- コールバック型変更の波及先は `RenameSpeakerPopoverView.swift` だけでなく、配線側の
  `TranscriptTabView.swift` / `MeetingWorkspaceView.swift` も含む（V2 スコープ）

### 5.3 enrollment 音声の切り出し（pure function）

`OverrideEnrollmentSampleResolver.resolveSampleSlices(...)`（新設・pure、
`Kikimi/Diarization/OverrideEnrollmentSampleResolver.swift`）:

```
入力: 対象セグメント群（id, startMs, endMs）, 全 turns, recordings[],
      minEnrollSpeechMs, maxSampleCount
出力: [EnrollmentSampleSlice]?（既存型を再利用）
```

セグメントごとの採用規則（保守的に、純度の低いサンプルは捨てる）:

- `SegmentAttribution.attribute` の結果が `.single(slot)` のセグメントのみ採用する。
  `.mixed` は複数話者の音声が混ざるため**丸ごと除外**（debug ログ）。`.unattributed`
  （turn が無い「Speaker ?」行への override）も音声区間を特定できないため除外
- 採用セグメントは「セグメント範囲 ∩ primary slot の turns」を音声区間とし、さらに
  **複数 slot の turn が同時に重なる区間（同時発話）を除外**する（クロストーク汚染防止）
- 区間 → `system_NNN.wav` 内サンプル範囲への変換・録音区間跨ぎの分割・時系列順の
  `maxSampleCount` 打ち切りは `VoiceprintEnrollmentSampleResolver` と同じ規則
  （変換ヘルパは共有してよい）
- 同一人物（同一 identity。5.4 節）の複数 override は**音声を合算**して累計判定する。
  累計発話が `min_enroll_speech_ms` 未満なら `nil`（info ログして学習スキップ。
  単発の短い override では学習しない — 短サンプルからの弱い声紋がかえって誤マッチ源になるため）
- **限界の明示**: diarizer が話者交代を見逃して 2 人を 1 slot に併合した場合
  （callhome variant 選定の動機だった既知の失敗モード。13 章 2.1 節）、`.single` 判定・
  同時発話除外をすり抜けて両者の声が混ざったサンプルになり、訂正先 speaker を α = 0.3
  （新規登録なら実質 α = 1.0）で汚染し得る。検出手段がないため残余リスクとして受容し、
  実戦での顕在化は §12 で追跡する（救済は声紋リセット）

### 5.4 enrollment 実行（録音中も即実行）

> **追記（実測後の方針変更・2026-07-07）**: 当初は override 由来 enrollment を **Ended 時のみ**
> 実行していたが、「『この発言だけ』でもその発話の音声は存在し、話者はユーザーが与えた正解ラベル
> なので即学習してよい」という要件により、**`overrideSegmentSpeaker` から状態を問わず
> （Recording / Paused / Ended いずれでも）段階 1〜2 を即実行**するよう変更した。効果:
> - 訂正した発話の実音声から声紋を即学習する（会議終了まで待たない）。同一人物を複数回訂正すれば
>   音声は従来どおり集約され、累計が `min_enroll_speech_ms` を越えた時点で登録/EMA が走る
> - `globalSpeakerId` の write-back（段階 2）で名簿へ即追加され、closed-set 再照合
>   （design 22 §3）が有効化されて他スロットの誤判定も会議中に止まる
> - `min_enroll_speech_ms` ゲート・優先順位・dedup ガード（`lastMatchedSessionId`）は不変。
>   単発の短い override は従来どおり累積待ち（空 embedding では登録しない）
>
> 以降の記述の「Ended 時」はトリガの一つに読み替える（Ended hook からの最終 catch-all 呼び出しと
> §5.5 の再オープン回収は従来どおり残る）。

`applyDiarizationEndedHooks`（および `overrideSegmentSpeaker`・再オープン回収）が呼ぶ
`applyVoiceprintEnrollmentUpdates` の処理は 2 段階に分ける。

**段階 1（同期・軽量）: 勝者の確定**

speaker ごとの「今セッションの代表サンプル」を、優先度付きで **1 つに確定**する。

1. `.user` slot の embedding（既存の勝者選定。ユーザーが slot ごと確定した最強シグナル）
2. **override 集約サンプル**（新設。per-segment の明示ラベル）
3. `.auto` slot の embedding（従来どおり。ただし M3 の不信任 slot は除外）

- **5.3 節の resolver（pure・軽量）は段階 1 で同期実行する**。override 集約が `nil`
  （累計発話不足・対象が全て `.mixed` / `.unattributed`）なら候補 2 を外し、次点の
  健全な `.auto` slot（候補 3）へ**フォールバックして通常 EMA を適用する** —
  「override 名 == slot 名の確認」ケースで学習機会を失わないため。段階 1 を抜けた時点で
  勝者は確定しており、以降の優先順位の逆転はない
- 勝者が slot embedding（候補 1・3）の speaker → 従来どおりその場で
  `applyMovingAverageUpdate` を適用する
- 勝者が override 集約（候補 2）の speaker → 段階 2 へ。**抽出完了までその speaker への
  slot 由来 EMA は走らせない**（先に α = 0.1 の auto 更新が入ると dedup ガードで
  override 由来の α = 0.3 が弾かれ、優先順位が逆転するため）。段階 2 の抽出が失敗した場合も
  slot 由来へは**フォールバックしない**（意図的。8 章の失敗モード表参照 —
  抽出失敗の背後には WAV 欠損等があり、同じセッションの slot embedding の信頼性も
  疑わしいため、そのセッションはスキップを受容する）
- 同順位内の決定規則は既存どおり（slot ID 昇順）。override 集約はセグメント ID 昇順で決定的
- speaker ごとに適用は 1 回だけ（`lastMatchedSessionId` の dedup ガードは変更なし）
- **配線**: 現行の `applyDiarizationEndedHooks` は `speaker_assignments.json` しか読まない。
  resolver / `DisputedSlotDetector` のために transcript セグメント（`transcriptRows` の
  id / startMs / endMs）・diarization turns（`diarizationTurns`、backfill 済みでなければ
  `SessionHandle.readDiarizationTurns()`）・`meta.recordings` を渡す配線を追加する
  （データはすべて既存。新規 I/O は turns の再読み込みのみ）

**段階 2（fire-and-forget・重量）: 抽出と適用**

override 集約が勝者になった speaker / 新規名 identity について、背景 Task で実行する
（WAV フォールバックと同じ流儀。WeSpeaker モデルの初回 DL が数十秒あり得るため
`endMeeting()` をブロックしない。Task はテスト用にプロパティ保持する）。

1. 段階 1 で解決済みのサンプル範囲を `AVAudioFileSampleReader` で読み出し、
   `VoiceprintExtractor.extractEmbedding(from:)` で embedding を得る
2. identity が既存話者（`globalSpeakerId` あり）→
   `applyMovingAverageUpdate(alpha: userCorrectionAlpha)`（α = 0.3）
3. identity が新規名 → `registerSpeaker(name:embedding:)` で新規登録し、その名前を持つ
   全 override に `globalSpeakerId` を **write-back** する（`updateSpeakerAssignments` 経由）。
   write-back により Ended → 再開 → 再 Ended の再実行が重複登録にならない
   （write-back 失敗時も 4 章の名前正規化が保険になる）
4. 全経路 best-effort（抽出失敗・WAV 欠損は warning ログのみ）

**identity の定義**: override の `globalSpeakerId`（あれば）→ 正規化（4 章）で解決した既存話者
（`.ambiguous` は学習スキップ。4 章）→ それ以外は trimmed 表示名をキーとする新規名グループ。
同名の override は 1 identity に束ねる。

### 5.5 override 変更時の再実行と未完了 enrollment の回収

override を追加・変更するたびに段階 1〜2 を再実行する（`overrideSegmentSpeaker` から、状態を問わず
起動。§5.4 追記のとおり Recording / Paused / Ended いずれでも走る）。あわせて **participants マージも
実行する** —
現行の `overrideSegmentSpeaker` は `mergeDiarizationParticipantsIfEnded()` を呼んでいないため、
呼び出しを追加する（5.6 節で override 名を収集対象に加える以上、Ended 後の override 追加にも
反映が必要）。

- 既存話者への EMA は `lastMatchedSessionId` ガードにより同一セッション 2 回目以降は no-op
  （debug ログ）。**この制約の含意を明示する**: Ended 時点で汚染サンプル（誤マッチのままの
  `.auto` slot）が既に EMA 適用されていた場合、Ended 後の訂正はそれを**取り消せない**
  （EMA は不可逆で、dedup ガードにより同一セッションからの再適用もできない）。
  M3 の汚染防止が効くのは **Ended 前の訂正まで**。Ended 後に誤マッチに気付いた場合の救済は
  既存の「声紋リセット」→ 次セッションで手動割り当て → 再学習、とする
- 新規名の登録は Ended 後でも走る（WAV・turns はすべて残っているため）
- **未完了 enrollment の回収**: 段階 2 は fire-and-forget のため、Ended 直後にアプリを終了すると
  write-back 前に Task が消え得る。回収経路として、Ended セッションのウィンドウを開いた時
  （`onAppear` の diarization backfill 後）に「`globalSpeakerId` の無い新規名 override」が
  残っていれば段階 1〜2 を再実行する。write-back 済みなら条件に合致せず no-op、
  EMA は dedup ガードが効くため冪等

### 5.6 participants への反映

override 由来の表示名も Ended 時の participants マージ（13 章 6.2 節）の対象に加える
（`mergeDiarizationParticipants` の収集元に `segmentOverrides` の `displayName` を追加）。
重複排除は従来どおり完全一致のみ。

## 6. M3: 不信任 auto slot の EMA 除外とヒント表示

### 6.1 不信任（disputed）の判定

`DisputedSlotDetector.disputedSlots(assignments:transcriptSegments:turns:) -> Set<String>`
（新設・pure）:

- 各 override について、対象セグメントの `SegmentAttribution.attribute` を求める。
  **不信任判定の対象は結果が `.single(slot)` のセグメントのみ**（5.3 節の M2 サンプル採用規則と
  同じ基準）。`.mixed` は複数話者の音声が混ざり、ユーザーの override が secondary 話者側を
  指している可能性があるため、primary slot を不信任にすると健全な slot を EMA から誤って
  除外し得る — 対象外とする。`.unattributed`（turn が無い「Speaker ?」行への override）は
  そもそも対象 slot を特定できないため対象外
- 対象セグメントの `.single` slot の割り当てが `assignedBy == .auto` かつ
  `displayName != override.displayName`（どちらも trimmed 比較）なら、その slot を不信任とする
- `.user` slot は不信任にしない（slot ごとの明示リネームは per-segment 訂正より強い意思表示。
  slot リネーム後に一部セグメントだけ override するのは「slot は正しいが、この発言だけ別人」
  という正常な使い方）
- override 名と slot 名が一致する場合は不信任にしない（確認・強調にすぎない）

### 6.2 EMA からの除外

`applyVoiceprintMovingAverageUpdates` の候補選定（5.4 節・段階 1）で、不信任 slot を
`.auto` 候補から除外する。効果:

- 誤マッチが疑われる slot の embedding（= 実際は新規話者の声）が、誤マッチ先の既存話者の
  声紋を汚染しなくなる
- その speaker に他の健全な候補（`.user` slot・override 集約・別の `.auto` slot）があれば
  そちらから更新され、無ければ warning なしでスキップ（誤マッチ疑いのスキップは正常系なので
  13 章 8 章の「embedding が無い」warning とはログレベルを分け、info とする）

### 6.3 ポップオーバーのヒント

`RenameSpeakerPopoverView` の「この発言だけ」セクションに、当該行の primary slot が
`.auto` 割り当てのときだけ 1 行の caption を出す:

「自動判定が間違っている場合は、上の『すべての発言に適用』を使うと以後の会議でも正しく認識されます」

- 静的テキストのみ。対話的な提案フロー（「slot 全体を変更しますか？」ダイアログ）は入れない —
  M2 で override 自体が学習されるようになるため誘導の必要性が下がっており、
  ポップオーバーの apply 後継続表示など UI 状態管理の複雑さに見合わない

### 6.4 不信任 slot の再照合リセット（2026-07-07 追記）

M2/M3 を入れても、**クリーンな 1 人 slot が誤って auto 実名化された場合、「この発言だけ」を
繰り返しても収束しない**という症状が残った。override はその 1 セグメントの `segment_overrides`
表示だけを直し、slot の `.auto` 割り当て（`display_name`/`assigned_by`）には触れない。closed-set
rematch（design 22 §3）は `display_name != nil` の slot を巻き戻さない仕様なので、同じ slot に
新しく帰属するセグメントが誤名を出し続ける。§6.3 のヒントで「すべての発言に適用」へ誘導する設計
だが、per-segment 訂正を繰り返すユーザーには収束経路が無かった。

対策として、`DisputedSlotDetector`（§6.1、EMA 除外用途では未使用になっていた）を**再照合リセット**に
再利用する:

- override が矛盾させた slot（`.single` 帰属・`assigned_by == .auto`・slot 名 ≠ override 名。
  §6.1 の disputed 判定そのもの）を検出し、その slot の `display_name`/`global_speaker_id` を
  **nil にリセット**（`embedding` と `assigned_by == .auto` は保持 = 匿名 auto slot に戻す）
- 直後に closed-set rematch（design 22 §3）を実行し、**訂正済み名簿で再評価**する。誤った既存話者は
  名簿外なので closed-set から除外され、slot は正しい話者（訂正で名簿に載った本人）に再マッチする
- **ガード（closed-set 限定）**: 名簿が空（open-set）のときはリセットしない。open-set 再照合は
  同じ誤った最近傍に戻すだけで、表示がちらつくだけの無意味な往復になるため。訂正 override の
  enrollment write-back が本人を名簿に載せて初めてリセットが起きる（`overrideSegmentSpeaker` /
  `writeBackOverrideGlobalSpeakerId` が `autoAddParticipantHint` の直後に呼ぶ）
- **design 22 §3「実名確定 slot は巻き戻さない」の限定的緩和**である旨を明記する: ユーザーが明示的に
  矛盾させ、かつ closed-set が「巻き戻し先＝訂正済み本人」を保証するときだけ巻き戻す。表示退行は
  「誤名 → 正名」なので望ましい方向
- **べき等・自己収束**: 再マッチで slot 名が override 名と一致すれば以後 disputed 判定に載らず、
  再実行しても触らない。`.mixed` slot は disputed 判定されないので、複数話者を正当に含む slot を
  巻き戻すことはない（§5.3/§6.1 の併合 slot 残余リスクは「匿名 or 2 人のどちらか」に落ちるだけで
  誤名より悪化しない）
- 実装: `MeetingWorkspaceViewModel+DisputedSlotReset.swift` の `resetDisputedSlotsAndRematchIfNeeded()`。
  再照合は §3.2 の ViewModel 側 rematch（`rematchAnonymousSlotsViaViewModel`）を coordinator 併存時も
  用いる（coordinator の `rematchAnonymousSlots()` は `DiarizationCoordinating` プロトコル非公開で、
  名簿無変化では内部起動しないため。両経路とも同じ actor 直列化書き込み + 名簿再検証 guard を通る）

## 7. config.yaml（変更まとめ）

```yaml
diarization:
  speaker_match_margin: 0.05    # 新設（3.4 節）。0 で無効
```

他の対策（M2/M3）は config 追加なし。`min_enroll_speech_ms` は override 学習でも同じ値を使う。

## 8. 失敗モード

13 章 8 章の「diarization は全経路で best-effort」原則をそのまま踏襲する。

| 失敗 | 振る舞い |
|---|---|
| マージン棄却（rejectedByMargin） | slot は匿名（Speaker N）のまま。info ログ。ユーザーがピッカーで割り当てれば α = 0.3 で学習される |
| override 対象が全て `.mixed` / `.unattributed`、または累計発話 < `min_enroll_speech_ms` | 段階 1 で override 集約が候補から外れ、健全な `.auto` / `.user` slot 候補へフォールバック（info ログ。表示名は従来どおり有効） |
| override enrollment（段階 2）の抽出失敗 / WAV 欠損 | warning ログしてスキップ。**slot 由来 EMA へはフォールバックしない**（意図的。5.4 節 — 段階 1 で先送りした時点でこのセッションの更新機会は override 集約に賭けている） |
| Ended 直後のアプリ終了で段階 2 の Task が消失 | write-back 前なら痕跡なし。Ended セッションの再オープン時に「`globalSpeakerId` の無い新規名 override」を検出して再実行（5.5 節）。EMA 分は dedup ガードの範囲で回収 |
| write-back（`globalSpeakerId`）失敗 | error ログ。再 Ended / 再オープン時に名前正規化（4 章）で同一 speaker に解決され重複登録を回避 |
| 名前正規化が `.ambiguous`（同名複数一致） | 登録・EMA とも抑止（4 章）。表示名のみ有効。info ログ |
| 不信任 slot 除外により候補ゼロ | その speaker の EMA をスキップ（info ログ。誤マッチ疑いなので正常系） |
| Ended 後 override 変更時、EMA が dedup ガードで no-op | 仕様（5.5 節）。debug ログ。当該セッションで既に適用済みの汚染 EMA は取り消せない — 救済は声紋リセット |

録音・STT・セッション確定処理をブロックする経路は一切追加しない。

## 9. テスト

- **単体（swift-testing / XCTest）**
  - `VoiceprintMatchPolicy`: 閾値境界・マージン境界・次点なし（単独登録）・margin = 0 で従来挙動・
    リセット済み speaker（空 embedding）が候補/次点から除外されること
  - `VoiceprintStore.findMatchCandidate`: 空 DB・1 人・複数人・次点の距離とチェック /
    **同名重複 DB でマージン棄却しないこと**（同一人物の重複エントリ 2 件 + 本人に近い
    embedding を照合 → 次点が同名エントリから取られず `runnerUpDistance == nil`
    または異名 speaker の距離になり、`accepted` になる）/ 全員同名なら `runnerUpDistance == nil`
  - 名前正規化: 完全一致 1 人 → `.existing` 変換、0 人 → `.new`、同名複数 → `.ambiguous`
    （slot 経路で登録されず localOnly になること・override 経路で学習スキップされること）、
    前後空白の trim
  - `OverrideEnrollmentSampleResolver`: `.single` 採用 / `.mixed`・`.unattributed` 除外 /
    同時発話区間の除外 / 複数 override の合算と `minEnrollSpeechMs` 境界 / `maxSampleCount`
    打ち切り / 録音区間跨ぎ分割
  - `DisputedSlotDetector`: auto + 名前不一致（`.single`）→ 不信任 / auto + 名前一致 → 対象外 /
    user slot → 対象外 / override 対象が `.mixed` → 対象外（primary slot を不信任にしない）/
    `.unattributed` → 対象外
  - Ended 時の勝者選定: `.user` slot > override 集約 > `.auto` slot の優先順位 /
    不信任 slot 除外 / override 勝者時に slot 由来 EMA が先行しないこと /
    **override 集約が resolver で `nil` のとき `.auto` slot へフォールバックすること** /
    段階 2 抽出失敗時に slot 由来へフォールバックしないこと /
    dedup ガードとの相互作用（speaker あたり 1 回）
  - 新規名 enrollment: 登録 + write-back / write-back 後の再 Ended が重複登録しないこと /
    **再オープン時の回収**（`globalSpeakerId` なし新規名 override で再実行、write-back 済みなら no-op）
  - Ended 後の override 変更で participants マージが走ること（5.5 節）
  - `SegmentSpeakerOverride` の Codable: `global_speaker_id` あり / なし（旧ファイル）round-trip
- **統合（kikimi-verify）**
  - 複数話者ダミー音源 → override（新規名）→ 会議終了 → `voiceprints.json` に登録されること
  - 別セッションで同じ声が自動実名化されること（可能なら。ダミー音源の声紋再現性次第）
  - ポップオーバーに既存話者ピッカーとヒント caption が出ること（スクリーンショット確認）

## 10. 実装フェーズ分割

| モジュール | 内容 | 依存 |
|---|---|---|
| **V1** | M1: `VoiceprintMatchCandidate` + `VoiceprintMatchPolicy` + coordinator の置き換えとログ + config `speaker_match_margin`。`findBestMatch` 削除に伴う既存テスト（`VoiceprintStoreTests` に 6 箇所の呼び出し）と doc コメント参照（`VoiceprintStore.swift` / `RealtimeDiarizationCoordinatorTests.swift` / `VoiceprintMapLayoutTests.swift`）の移行を含む | なし |
| **V2** | 共通正規化（`NormalizedRenameTarget`）+ `SegmentSpeakerOverride.globalSpeakerId` + ポップオーバー（ピッカー・ヒント caption）+ `overrideSegmentSpeaker` の submission 化。コールバック型変更の波及（`TranscriptTabView.swift` / `MeetingWorkspaceView.swift`）を含む | なし（V1 と独立） |
| **V3** | `OverrideEnrollmentSampleResolver` + `DisputedSlotDetector` + Ended 時の勝者選定拡張（配線含む）・fire-and-forget enrollment・write-back + Ended 後 override 変更の再実行・再オープン時の回収 + participants 反映 | V2 |

V1 と V2 は並行実装可。V3 が本丸で、V2 のデータモデルの上に載る。

## 11. 13 章からの逸脱（確定後に 13 章へ反映する事項）

| 箇所 | 現行記述 | 本設計 |
|---|---|---|
| 4.3 節 `segment_overrides` | `{"display_name": "佐藤さん"}` のみ。「将来のセグメント単位声紋分類の教師データを兼ねる」 | `global_speaker_id` を追加し、Ended 時 enrollment の教師データとして**今回から実際に使う** |
| 4.4 節 EMA 更新 | 対象は slot 単位（`.user` 優先） | 候補に override 集約を追加（`.user` slot > override > `.auto` slot）。不信任 `.auto` slot を除外 |
| 4.4 節 登録経路 | 「登録経路はユーザーのリネーム操作のみ」 | override（per-segment のリネーム操作）経由の登録を追加。「ユーザー操作起点のみ」の原則は維持 |
| 2.2 節 / 7 章 照合 | 「照合閾値 0.65 の最近傍」 | マージン判定を追加（`speaker_match_margin`） |
| 6.1 節 ポップオーバー | 「この発言だけ」はフリーテキストのみ | 既知話者ピッカーとヒント caption を追加 |
| §15 距離ログ | 「auto マッチ失敗時の距離ログを Phase 4 開始前に仕込む」 | 成功・マージン棄却込みで本設計で実装（前倒し） |

kikimi.md 側の乖離も追跡する: 12 章 config.yaml サンプルには `diarization:` セクション自体が
無い（design 13 以来の既存乖離）。`speaker_match_margin` 追加を機に、実装完了後
`diarization` セクション全体を kikimi.md 12 章へ反映する。

## 12. Open Questions（実測後に判断する事項）

- `speaker_match_margin` 既定 0.05 の妥当性（M1 のログで同一人物・別人の距離分布を見て調整）
- ~~`speaker_match_threshold` 既定 0.65 を下げるか（同上。誤マッチ頻度がログで定量化できてから）~~ →
  実測により 0.45 へ引き下げ済み（Settings 話者タブで、一度も EMA 更新されていない別人3名の
  素の embedding 同士が cosine 距離 0.51/0.60 となり 0.65 では誤警告される事例を確認。3.4 節参照）
- override 学習の発話量ゲートを `min_enroll_speech_ms`（5 秒）より下げるか
  （単発 override で学習されないケースがどの程度不満になるか実戦で確認）
- **既存 `voiceprints.json` の同名重複エントリの整理方法**（3.2 節参照）。次点の異名限定により
  照合の退行は起きないが、重複エントリ自体は残る。候補は (a) Settings 話者タブでの手動削除への
  誘導（同名検出時にバッジ表示など）、(b) 起動時 or Ended 時の自動 dedup（同名エントリの
  embedding を平均 or 新しい方を採用して 1 件に統合）。誤統合（実在の同名別人）のリスクが
  あるため、まずは (a) の手動誘導から入り、実戦で頻度を見て (b) を判断する
- **Ended 後訂正の EMA 取り消し**（5.5 節の制約）: per-session の pre-EMA スナップショット
  （speaker ごとに直前 embedding を保持し、同一セッション起因の更新を巻き戻せるようにする）を
  持つか。現状の救済は声紋リセットのみ。実戦で「Ended 後に誤マッチへ気付く」頻度を見て判断
- **slot 併合による override サンプル汚染**（5.3 節の残余リスク）が実際に起きる頻度（Phase 4）
- 13 章 14 章の複数声紋方式（multi-template enrollment）との合流点 — 本設計の override 集約
  サンプルは、複数声紋化した際「訂正の瞬間にそのチャネル用プリントを立てる」入力にそのまま使える
