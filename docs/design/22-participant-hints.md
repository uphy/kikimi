# 22. 参加者ヒント（クローズドセット照合と話者名簿）

対象読者: Kikimi 実装者（Claude Code 自身）。実装前に必ず読むこと。

参照元: `docs/design/21-diarization-accuracy-roadmap.md` §4.4（F4。方針決定の経緯と根拠）,
`docs/design/13-speaker-diarization.md`（話者分離の基本設計。特に 4.3〜4.4 節・5 節）,
`docs/design/20-voiceprint-misassignment-mitigation.md`（照合ポリシー・名前正規化）。

本設計の要点は以下のとおり。

- **セッションごとの「参加者名簿」を導入する**。任意入力。`sessions/<id>/participants.json` に
  `global_speaker_id` のリストとして保存し、表示名は `voiceprints.json` から解決する
- **名簿が 1 人でも設定されたら、声紋照合をクローズドセットに切り替える**。照合候補を
  名簿内の話者に限定し、名簿外の DB 話者には一切割り当てない。名簿ゼロなら従来どおりの
  オープンセット照合（本機能は丸ごと no-op）
- **suggest box で未登録話者を空 embedding（`[]`）のまま新規登録できる**。空 embedding は
  既存の「声紋リセット済み」の意味論（距離 `.infinity` で自動照合対象外・ピッカーには出る・
  最初のユーザー割り当て後の Ended 時学習で丸ごと採用）にそのまま乗り、新しい規約を増やさない
- **ユーザーの明示的な話者割り当て（slot リネーム・segment override）で名簿へ自動追加する**。
  auto 照合の結果からは追加しない（誤マッチの自己汚染ループ防止）。手動削除した話者は
  同一セッション内で自動再追加しない
- **名簿変更のたびに、匿名のまま棄却されている auto slot を再照合する**。embedding は
  `speaker_assignments.json` に永続化済みなので音声の再抽出なしで安価にできる。
  `.user` 割り当て済み・実名確定済みの slot は触らず、名簿からの削除で既存割り当てを
  巻き戻すこともしない。coordinator が存在しないセッション（録音未開始の再オープン
  Ended / Paused）では ViewModel 側フォールバックで同じ再照合を実行する（§3.2）。
  ライブ抽出との交錯は actor reentrancy で起き得るため、全 `.auto` 書き込み経路に
  書き込み直前の名簿再検証 guard を置く（§3.1）
- **名簿はサマリの participants にマージしない**。participants に入るのは従来どおり
  「実際に発言した人」と LLM 抽出のみ（欠席者・書き間違いがサマリ・Wiki export を汚さない）
- UI は Draft 準備専用画面と準備タブのみ（会議タブには置かない）。config 追加はなし

## 1. データモデル

### 1.1 `sessions/<id>/participants.json`（新設・上書き）

```json
{
  "participant_ids": ["b3f1...", "c4a2..."],
  "removed_participant_ids": ["d5e3..."]
}
```

| フィールド | 型 | 説明 |
|---|---|---|
| `participant_ids` | `[String]` | 名簿。`voiceprints.json` の speaker id。追加順を保持（UI 表示順） |
| `removed_participant_ids` | `[String]` | ユーザーが手動削除した speaker id。**自動追加の抑止リスト**（同一セッション内で割り当てが再発しても自動では戻さない）。suggest box からの手動再追加時は両リスト間を移動する |

- 型は `SessionParticipants`（`Kikimi/SessionStore/DiarizationModels.swift` に追加。
  `SessionJSONCoding` 規約 — CodingKeys は camelCase のまま、snake_case はエンコーダ戦略に任せる）
- 両リストは排他（同じ id が両方に入らない）。`mutate` ヘルパ
  （`addParticipant` / `removeParticipant`）で不変条件を守る
- 防御的 decode: ファイル欠落・破損・キー欠落は空（`SessionParticipants()`）として読む。
  空 = 名簿未設定 = オープンセット照合
- 表示名は保存しない（`voiceprints.json` から解決。リネーム追従が自動になる）

### 1.2 SessionStore / SessionHandle

07-session-store の規約に従う。

- `SessionFile` に `.participants` ケースを追加（`participants.json`）
- `SessionHandle` に以下を追加（`updateSpeakerAssignments` と同型）:
  - `func readParticipants() -> SessionParticipants` — `readJSONIfPresent ?? .init()`
  - `func updateParticipants(_ mutate: (inout SessionParticipants) -> Void) throws` —
    read-modify-write を actor 呼び出し 1 回で完結（auto 追加と UI 操作の並行書き込み対策）、
    `atomicWriteJSON`

### 1.3 based_on 複製

`SessionStore.createDraftSession(basedOn:)`（`SessionStore.swift`）で、`context.md` /
`summary_template.md` と同様に複製する:

- 複製元の `participants.json` から **`participant_ids` のみ**コピーする
  （`removed_participant_ids` はコピーしない — 削除記録はセッション内の自動再追加抑止であり、
  会議を跨いで意味を持たない）
- 複製元にファイルが無い・読めない場合は何も書かない（新規セッションはファイルなし = 名簿なし）
- 準備タブの「他セッションから複製…」（`DuplicateFromSessionSheet` — context / template の
  上書きコピー）は**本設計のスコープ外**（複製対象に参加者を加えるかは実戦で必要になってから）

## 2. 照合のクローズドセット化

### 2.1 VoiceprintStore: 候補列挙のフィルタ

`findMatchCandidate` に許可リストを追加する:

```swift
func findMatchCandidate(
    embedding: [Float],
    allowedSpeakerIds: Set<String>? = nil
) -> VoiceprintMatchCandidate?
```

- `nil` = 従来どおり全 speaker が候補（オープンセット）
- 非 `nil` = **最近傍・次点（runner-up）とも許可リスト内の speaker からのみ**選ぶ
  （マージン判定は名簿内の話者同士で従来どおり機能する）
- 空 embedding の除外（`isFinite` guard）・同名 runner-up 除外の既存規則はそのまま
- **空集合は渡さない**のを呼び出し側の契約とする（名簿ゼロ = オープンセットは呼び出し側で
  `nil` に解決する）。防御として空集合が来たら `nil` を返す（候補なし）
- `VoiceprintMatchPolicy`（pure function）は**無変更**

### 2.2 Coordinator: 名簿の保持と適用

`RealtimeDiarizationCoordinator`（actor）に名簿の状態を持たせる:

- `var participantHintIds: Set<String> = []`（空 = 名簿未設定）
- `DiarizationCoordinating` プロトコルに
  `func updateParticipantHints(_ ids: Set<String>) async` を追加。
  格納後、変化があれば §3 の再照合を起動する
- `extractAndMatchVoiceprint`（`+Voiceprint.swift`）の照合呼び出しを
  `findMatchCandidate(embedding:allowedSpeakerIds: participantHintIds.isEmpty ? nil : participantHintIds)`
  に変更。判定・ログ・`assignmentUpdatesContinuation.yield` は既存のままだが、
  **accepted 後の `.auto` 書き込み直前に §3.1 の名簿再検証 guard を追加する**
  （actor reentrancy により、`allowedSpeakerIds` を引数評価した時点と書き込み時点で
  名簿が異なり得るため。フィルタだけでは不変条件を守れない）
- 距離ログ（design 20 §3.3）に `closedSet=<bool> rosterSize=<n>` を追記する
  （閾値チューニング時に照合モードを区別できるように）

**名簿の初期供給と更新経路**: coordinator は `participants.json` を自分では読まない
（factory のシグネチャを変えない）。`MeetingWorkspaceViewModel` が所有者として、
(a) coordinator 生成直後（`diarizationCoordinatorIfEnabled()` の生成分岐）と
(b) 名簿変更のたび、に `updateParticipantHints` を push する。

## 3. 名簿変更時の再照合（rematch）

coordinator に追加する:

```swift
func rematchAnonymousSlots() async
```

1. `sessionHandle.readSpeakerAssignments()` を読む
2. **対象 slot** を選ぶ: `embedding` が非 nil・非空、かつ `displayName == nil`
   （= 抽出済みだが一度も実名が付いていない匿名 slot）。以下は対象外:
   - `assignedBy == .user` の slot（ユーザー確定は不可侵。既存の保護と同じ）
   - `displayName != nil` の `.auto` slot（実名確定済み。名簿の削除・変更で
     **巻き戻さない** — 表示の突然の退行を避け、誤りは通常の訂正経路で直す）
     - **例外（2026-07-07・design 20 §6.4）**: ユーザーが「この発言だけ」で明示的に矛盾させた
       **不信任 slot** は、rematch 前に `display_name`/`global_speaker_id` を nil にリセットして
       この対象条件（`displayName == nil`）に載せ、訂正済み closed-set で再照合する。
       「実名確定 slot を巻き戻さない」の限定的緩和（誤名→正名の退行は望ましい方向。空名簿では
       リセットしない）。リセット判定は `DisputedSlotDetector`、実装は
       `MeetingWorkspaceViewModel+DisputedSlotReset.swift`
3. 各対象 slot について `findMatchCandidate`（§2.1 のフィルタ付き）→
   `VoiceprintMatchPolicy.decide` → accepted なら既存の auto 書き込みと同一の経路で
   `speaker_assignments.json` へ書き込み（`.user` guard + **§3.1 の名簿再検証 guard** 込み）、
   `assignmentUpdates` を yield
4. ログは既存の距離ログ形式に `trigger=rematch` を付けて出す

- **呼び出し契機**: `updateParticipantHints` で名簿が実際に変化したとき（coordinator 内部で
  起動）。coordinator が存在しないセッション（録音未開始の再オープン）では §3.2 の
  ViewModel 側フォールバックで実行する
- ライブ抽出（`extractAndMatchVoiceprint`）との交錯は **actor reentrancy により起き得る**。
  防御は §3.1 の書き込み直前再検証で行う（「actor 直列化で構造的に起きない」は誤りなので
  根拠にしない）
- 再照合はべき等（同じ名簿で 2 回呼んでも 2 回目は全滅 or 同一結果）。抽出のマイルストーン状態
  （旧 `extractedSlots`。13 章 5 節の 2026-08-01 追記でマイルストーン方式に変更）は変更しない
  ——再照合は永続化済み embedding に対して照合だけをやり直す。live 側の再抽出で embedding が
  新しくなれば、その後の再照合は自動的に新しいほうを使う
- 名簿ゼロへの変化（最後の 1 人を削除）でも呼んでよいが、匿名 slot がオープンセットで
  マッチし得るのは従来挙動と同じなのでそのまま許容する

### 3.1 書き込み直前の名簿再検証（actor reentrancy 対策）

Swift の actor は **reentrant** であり、fire-and-forget で走る `extractAndMatchVoiceprint`
（`RealtimeDiarizationCoordinator+Voiceprint.swift`）は `await voiceprintExtractor.extractEmbedding` /
`await sessionHandle.updateSpeakerAssignments` / `await voiceprintStore.findMatchCandidate` の
各サスペンションポイントで `updateParticipantHints` → rematch と交錯し得る。具体的な失敗経路:
抽出タスクが旧名簿（例: 空 = オープンセット、または旧名簿 {A}）を引数評価済みの
`findMatchCandidate` から結果を得た後、書き込み前のサスペンション中にユーザーが名簿を
設定・変更（A を削除し B を追加）→ rematch が新名簿で B を書く → 抽出タスクが再開して
旧名簿判定の A で上書き — 「名簿外の DB 話者には一切割り当てない」という本設計の核心不変条件が
破れる。そこで以下を仕様とする。

- **`.auto` 書き込みの直前（accepted 判定後、`updateSpeakerAssignments` を呼ぶ前）に、
  その時点の `participantHintIds` で候補 speaker id を再検証する**:
  `participantHintIds.isEmpty || participantHintIds.contains(match.id)` を満たさなければ
  書き込みをスキップし、既存の距離ログ形式で `rejectedByRoster` を出す（rematch 経由なら
  `trigger=rematch` 付き）。この再検証は `findMatchCandidate` から復帰した後に coordinator
  actor 上で**同期的に**行うため、照合開始〜書き込み開始の間に入ったすべての名簿変更を捕捉する
- この guard は **ライブ抽出・rematch（§3 手順 3）・§3.2 の ViewModel 側 rematch の
  全 `.auto` 書き込み経路**に適用する。既存の `.user` guard と同居させる
- **残余ウィンドウ（明示的に許容）**: 最終の `updateSpeakerAssignments` 呼び出し自体の
  suspension 中に名簿が変わるケースだけは通り得る。これは (1) ウィンドウがファイル書き込み
  1 回分と極小、(2) 結果は `.auto` 割り当てでユーザーが通常の訂正経路で直せる、
  (3) 「名簿からの削除は既存割り当てを巻き戻さない」方針（§3 手順 2）と整合する、ため許容する。
  直後に走る rematch は実名確定済み slot を触らない仕様なのでこれを巻き戻すこともしない
- 連続した名簿変更で rematch が多重に走っても、各書き込みが直前再検証を通るため不変条件は
  保たれる（同一 slot への重複書き込みは同値上書きで無害）

### 3.2 coordinator 不在時の rematch（ViewModel 側フォールバック）

coordinator は `runRecordingSegmentStart` → `diarizationCoordinatorIfEnabled()`
（`MeetingWorkspaceViewModel+Diarization.swift`）でしか生成されないため、**再オープンした
Ended / Paused セッションで録音を開始していない間は coordinator が存在しない**。
「coordinator が居れば push」だけでは、会議後レビューでのリネーム → 名簿自動追加 →
他の匿名 slot の再照合（§4.2 の主要ユースケース。design 21 §4.4 E3b 対策）が無言で
スキップされてしまうため、以下のフォールバックを仕様とする。

- §4.1 の共通経路（永続化 → push）で `diarizationCoordinator == nil` の場合、
  **ViewModel 側で rematch 相当を直接実行する**（`+Participants.swift` 内）。VM 側からの
  声紋関連ファイル書き込みは `applyVoiceprintEnrollmentUpdates`（`+OverrideEnrollment.swift`）
  と同じ前例に従う
- 手順は §3 と同一: `sessionHandle.readSpeakerAssignments()` → 対象 slot 選定（§3 手順 2 と
  同一基準）→ `findMatchCandidate(embedding:allowedSpeakerIds:)` →
  `VoiceprintMatchPolicy.decide`（threshold / margin は `appConfig.data.diarization` から解決）→
  accepted なら `.user` guard + §3.1 の名簿再検証込みで書き込み
- 書き込み後は `assignmentUpdates` の yield ではなく、自分で `diarizationAssignments` を
  再読込して `recomputeSpeakerLabels()` を呼ぶ（自分が書いたので直接反映できる。
  `applyVoiceprintEnrollmentUpdates` と同じ形）
- ログは §3 手順 4 と同形式（`trigger=rematch`）に `source=viewmodel` を付ける
- **競合について**: coordinator 不在 = ライブ抽出が存在しないので §3.1 の交錯は原理的に
  起きない。実行途中に録音再開で coordinator が生成される瞬間はあり得るが、新 coordinator の
  抽出には最低 `min_enroll_speech_ms` の新規音声が必要なため実質重ならず、仮に重なっても
  両経路が同じ guard（`.user` + 名簿再検証）を通るので不変条件は保たれる

## 4. 名簿の編集とユーザー操作

### 4.1 ViewModel の状態と操作

`MeetingWorkspaceViewModel` に追加する（`+Participants.swift` として新設）:

- `@Published private(set) var participantHints: [ParticipantHintItem]` —
  UI 表示用。`ParticipantHintItem { id: String, name: String? }`（`name` は
  `knownVoiceprintSpeakers` から解決。解決できない id は `nil` = 「不明な話者」表示）
- `func addParticipantHint(_ submission: SpeakerRenameSubmission) async` —
  suggest box からの追加:
  - `.existingSpeaker(globalSpeakerId:name:)` → その id を名簿へ追加
  - `.newName(name)` → `NormalizedRenameTarget.resolve` で正規化し、
    `.existing` → 既存 id を追加 / `.new` → **`voiceprintStore.registerSpeaker(name:, embedding: [])`
    で空 embedding 登録**してその id を追加 / `.ambiguous`（同名複数）→ 追加せず
    warning バッジ表示（どの重複か機械では決められない。suggest box は id 選択が主経路なので
    実質ここには来ない）
  - 追加時、`removed_participant_ids` に居れば取り除く（手動再追加）
- `func removeParticipantHint(id: String) async` — `participant_ids` から外し
  `removed_participant_ids` へ移す
- `func autoAddParticipantHint(globalSpeakerId: String) async` — §4.2 のフックから呼ぶ。
  既収載・`removed_participant_ids` 収載なら no-op
- いずれも `sessionHandle.updateParticipants` で永続化 → `participantHints` を再構築 →
  coordinator が居れば `updateParticipantHints`（→ 内部で rematch）を push、
  居なければ §3.2 の ViewModel 側 rematch を直接実行する
- セッションオープン時（既存の diarization 状態ロードと同じタイミング）に
  `readParticipants()` で復元する

### 4.2 割り当てからの自動追加のフックポイント

`global_speaker_id` が確定する既存の 4 箇所に `autoAddParticipantHint` を挿す:

| フック | 場所 | タイミング |
|---|---|---|
| slot リネーム（既存話者選択 / 名前正規化で既存に解決） | `applyRename` の `.assignExisting` 適用後 | 即時 |
| slot リネーム（新規名 + slot embedding あり） | `applyRename` の `.registerAndAssign`（`registerSpeaker` 直後） | 即時 |
| slot リネーム（新規名 + embedding なし → WAV フォールバック） | `persistVoiceprintWavFallback` の write-back 成功後 | 登録完了時（非同期） |
| segment override（既存話者 / 正規化解決 / override 由来 enrollment の write-back） | `overrideSegmentSpeaker` で `globalSpeakerId` 確定時、および `writeBackOverrideGlobalSpeakerId` 成功後 | 即時 / 登録完了時（**録音中も**。design 20 §5.4 追記により enrollment は Ended 限定でなくなった） |

- **auto 照合（`extractAndMatchVoiceprint` / rematch）の accepted からは追加しない**。
  追加はユーザー操作起点のみ（design 21 §4.4 の自己汚染ループ防止）
- `.localOnly`（embedding なしで表示名のみ）の時点では追加しない（id 未確定のため。
  WAV フォールバックが成功すれば上記 3 行目で追加される）
- 自動追加も §4.1 の共通経路（永続化 → coordinator push、または coordinator 不在時は
  §3.2 の ViewModel 側 rematch）を通る。つまり**訂正 1 回で名簿が増え、他の匿名 slot が
  即座に再照合される** — 録音中（coordinator の rematch）でも、会議後レビューで再オープン
  したセッション（VM 側 rematch）でも成立する

### 4.3 suggest box の解決規則

- 入力テキストで `knownVoiceprintSpeakers`（`listSpeakers()`）を部分一致フィルタし、
  **既収載（名簿に居る）speaker は候補から除外**して行表示する。行選択 = id 確定
  （`.existingSpeaker` 送信）
- 入力が非空で、trimmed 完全一致の既存 speaker が **0 人**のときだけ
  「『◯◯』を新しい話者として登録」行を出す（design 20 §4 の重複登録防止と同じ思想。
  同姓同名の別人を意図する場合は「田中さん（営業）」等の識別子付き名でエスケープ —
  既存方針の踏襲）
- Enter でのフリーテキスト確定は `.newName` として送信（§4.1 の正規化に乗る）

## 5. UI（PrepContentView）

`PrepContentView` は ViewModel 非依存（`@Binding` + クロージャ注入）の既存設計を維持する。

- **配置**: 事前メモ（context）セクションの直後、「▸ サマリの構成をカスタマイズ」の前に
  「参加者」セクションを追加。Draft 専用画面・準備タブの両方に同じ UI が出る
  （`showsWatchersSection` とは無関係）
- **注入するインターフェース**:
  - `participantHints: [ParticipantHintItem]`
  - `knownSpeakers: [VoiceprintSpeaker]`（suggest 候補。親が `refreshKnownVoiceprintSpeakers()`
    済みのものを渡す）
  - `onAddParticipant: (SpeakerRenameSubmission) -> Void`
  - `onRemoveParticipant: (String) -> Void`
- **表示**:
  - 追加済み参加者を 1 行 1 人で列挙（名前 + 削除ボタン ×）。`name == nil`（DB から
    削除済み等で解決不能）は「不明な話者」+ 削除ボタンのみ
  - suggest box: `TextField` + 入力中のみ候補リストを下に表示（§4.3 の規則）。
    実装は R2 ピッカーの `Menu` 流儀に合わせた最小構成でよい（NSPopover 系は
    kikimi-verify で検出不能なため避ける）
  - キャプション（常時）: 「入力すると、話者の自動認識をこの参加者に絞り込みます。
    未入力ならすべての登録話者から照合します」
  - 空 embedding で登録した直後の行には「声紋未登録 — 会議中に一度発言へ割り当てると
    学習されます」の caption を出す（design 13 §4.4 のリセット後バッジと同じ文脈）

## 6. 失敗モード

13 章 8 章の「diarization は全経路で best-effort」原則を踏襲する。

| 失敗 | 振る舞い |
|---|---|
| `participants.json` 欠落・破損 | 空名簿として読む（warning ログ）。= オープンセット照合。会議は記録できる |
| 名簿の id が `voiceprints.json` に存在しない（DB 側で削除された） | 照合フィルタには残しても無害（候補に現れないだけ）。UI は「不明な話者」表示 + 削除可能 |
| `updateParticipants` の書き込み失敗 | error ログ。メモリ上の名簿と coordinator への push は行う（次の変更で再書き込みされる）。録音・照合はブロックしない |
| 空 embedding 登録（`registerSpeaker`）の失敗 | warning ログ + 名簿追加もスキップ（suggest box にエラー表示）。既存の best-effort と同じ |
| rematch 中の書き込み失敗 | slot 単位で error ログしてスキップ（既存 `extractAndMatchVoiceprint` の失敗系と同じ） |
| ライブ抽出と名簿変更の交錯（actor reentrancy） | §3.1 の書き込み直前再検証で名簿外への `.auto` 書き込みを棄却（`rejectedByRoster` ログ）。最終書き込みの suspension 中の変更のみ通り得るが、明示的に許容（§3.1 の根拠 3 点） |
| diarization 無効（`enabled: false`） | 名簿の編集・永続化・based_on 複製は動く。照合も rematch も存在しないので効果はないだけ |
| coordinator 未生成（enabled だが録音未開始の再オープン Ended / Paused セッション） | 名簿変更時は §3.2 の ViewModel 側 rematch が走る（無言スキップにしない）。ライブ照合のクローズドセット化は次の録音開始（coordinator 生成 + push）から効く |
| 名簿削除直後に同じ話者へ auto 照合が走る | 削除は既存割り当てを巻き戻さない仕様（§3）。新規 slot は名簿外なので割り当てられない（照合フィルタ + §3.1 の再検証の二重防御） |

## 7. テスト

- **単体（swift-testing / XCTest）**
  - `SessionParticipants`: Codable round-trip（snake_case）・防御的 decode（キー欠落・破損）・
    add/remove の排他不変条件・手動再追加でリスト間移動
  - `SessionHandle`: `.participants` の relativePath / read（欠落 → 空）/ update の永続化
  - `VoiceprintStore.findMatchCandidate(allowedSpeakerIds:)`: `nil` = 従来挙動（既存テストが
    回帰ガード）/ フィルタで名簿外の最近傍が除外され名簿内の次善が選ばれる /
    runner-up も名簿内から取られる / 空集合 → `nil` / 空 embedding 除外との併用
  - `registerSpeaker(embedding: [])`: 登録成功・`findMatchCandidate` の候補に出ない・
    `listSpeakers()` には出る
  - Coordinator: 名簿ありでクローズドセット照合（名簿外 speaker が閾値内でも割り当てない）/
    名簿ゼロで従来挙動 / `updateParticipantHints` の変化検知と rematch 起動
  - 名簿再検証 guard（§3.1）: accepted 判定後・書き込み前に候補 speaker が名簿から外れて
    いたら `.auto` を書かない（`rejectedByRoster`）。fake extractor / store のサスペンションを
    制御して「照合結果取得 → `updateParticipantHints` → 書き込み再開」の交錯を再現する
    回帰テスト（reentrancy の防御を実装が省略しないためのガード）
  - rematch: 匿名 slot（embedding あり・displayName なし）が名簿追加後に accepted になる /
    `.user` slot・実名確定済み `.auto` slot を触らない / 名簿削除で巻き戻さない /
    べき等性 / 抽出マイルストーン状態（旧 `extractedSlots`）不変
  - VM 側 rematch（§3.2）: coordinator 不在で `addParticipantHint` →
    匿名 slot が accepted になり `speaker_assignments.json` に書かれる /
    `diarizationAssignments` 再読込と `speakerLabels` への反映 / 対象外 slot 不可侵は
    coordinator 側 rematch と同一基準
  - ViewModel: `addParticipantHint` の 3 分岐（existing / new → 空 embedding 登録 /
    ambiguous）/ `removeParticipantHint` → 自動再追加が抑止される /
    `applyRename`・`overrideSegmentSpeaker`・WAV フォールバック write-back からの自動追加 /
    coordinator への push
  - `SessionStore.createDraftSession(basedOn:)`: `participant_ids` のみコピー・
    `removed_participant_ids` 非コピー・複製元にファイルなしでもエラーにならない
- **統合（kikimi-verify）**
  - Draft 準備画面で参加者を追加（既存話者 + 新規名）→ `participants.json` の構造検証
  - 録音 → リネーム → 名簿への自動追加をファイルで確認
  - スクリーンショットで参加者セクション・suggest box・キャプションの表示確認

## 8. 実装フェーズ分割

| フェーズ | 内容 | 依存 |
|---|---|---|
| **P1** | データ層と照合コア: `SessionParticipants` + `SessionFile.participants` + `SessionHandle` API + `findMatchCandidate(allowedSpeakerIds:)` + coordinator の名簿保持・クローズドセット適用・rematch（§3.1 の名簿再検証 guard 込み）+ 単体テスト | なし |
| **P2** | ViewModel と自動追加: `+Participants.swift`（状態・add/remove/autoAdd・永続化・coordinator push・§3.2 の VM 側 rematch フォールバック）+ 4 フックポイント + `createDraftSession(basedOn:)` の複製 + 単体テスト | P1 |
| **P3** | UI: `PrepContentView` 参加者セクション（suggest box・一覧・キャプション）+ 配線（`MeetingWorkspaceView`）+ kikimi-verify | P2 |

## 9. LLM コンテキストへの参加者注入（追補）

名簿が設定されているセッションでは、参加者名を整形・サマリの LLM コンテキストにも含める。
STT は人名を誤変換しやすく、正しい表記のリストが事前知識にあると整形時の名前修正・サマリでの
表記統一に直接効くため。

- **注入内容**: `context.md` の内容の末尾に以下のブロックを連結した文字列を「LLM に渡す
  context」とする。名簿が空、または名前が 1 件も解決できない場合はブロックを付けない
  （完全に従来挙動）:

  ```
  【参加者】
  田中さん、佐藤さん
  ```

- **名前解決**: `participant_ids` を `VoiceprintStore.listSpeakers()` で名前に解決する
  （名簿順を保持）。解決できない id（DB から削除済み）はスキップ。
  `removed_participant_ids` は含めない
- **合成箇所**: 合成ロジックは pure function
  `ParticipantContextComposer.compose(context:participantNames:)`（新設）に置き、
  以下の 2 箇所から使う:
  - **Refinement**: `RefinementQueue` の `context.md` リロード時（キャッシュ更新時）に
    名簿も読み直して合成する。**反映粒度は既存の `context_refresh_batches` に従う**
    （名簿変更のたびに `refreshContextNow()` は呼ばない — 会議中の自動追加のたびに
    プロンプトキャッシュを無効化するとキャッシュ戦略が崩れるため。context.md 編集と
    同じ遅延反映として扱う）
  - **Summary**: `SummaryUpdater` がサマリ更新・全文再生成で `readContext()` を読む箇所で
    毎回合成する（サマリは毎回組み立て直すので即時反映。kikimi.md 7 章の既存方針どおり）
- **依存注入**: `RefinementQueue` / `SummaryUpdater` に `voiceprintStore`
  （既定 `.shared`。coordinator の既存パターンと同じ）と `sessionHandle.readParticipants()`
  への参照を追加する
- **サイズ上限との関係**: 合成後の文字列に既存の clamp（refinement 32KB / summary 16KB 相当）
  がそのまま適用される。極端に大きい context.md では参加者ブロックが切り落とされ得るが、
  best-effort として受容する
- **サマリの participants 欄との関係は変えない**: 注入はあくまで「LLM が参照できる事前知識」
  であり、§確定方針「名簿はサマリ participants にマージしない」はそのまま。LLM が注入された
  名前を participants_add で提案してくることはあり得るが、それは「会話に登場した人を LLM が
  抽出した」既存経路の範疇として受容する

## 10. 既存設計からの逸脱（確定後に反映する事項）

| 箇所 | 現行記述 | 本設計 |
|---|---|---|
| design 13 §4.4 | 「登録経路はユーザーのリネーム操作のみ」 | 参加者 suggest box からの空 embedding 登録を追加（ユーザー明示操作起点の原則は維持） |
| design 13 §4.1 / 4 章 | sidecar は diarization.jsonl / speaker_assignments.json | `participants.json` を追加 |
| design 13 §5「声紋照合（イベント駆動）」 | 照合候補はグローバル DB 全体 | 名簿設定時はクローズドセット。抽出一度きりは維持しつつ、名簿変更時の再照合（照合のみ）を追加 |
| kikimi.md 4 章 ディレクトリ構造 | — | `participants.json` を追記 |

config.yaml の変更はなし。
