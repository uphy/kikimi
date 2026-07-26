# 24. システム音声漏れ聞こえ対策（マイク誤帰属の抑制）

対象読者: Kikimi 実装者（Claude Code 自身）。実装前に必ず読むこと。

参照元: `kikimi.md` 6 章（2 ストリーム独立処理・診療化不要の前提）, 7 章（整形パイプライン・プロンプト設計・
`context_refresh_batches`）, 8.5 章（バックプレッシャ・「録音は絶対に止めない」原則）, 11 章（Wiki export の
`refined_text` 空文字フィルタ）, 12 章（config.yaml）。`docs/design/01-audio-capture.md`（2 ストリームキャプチャ・
共通 host time 座標系・`KIKIMI_TEST_INPUT` の仕様）, `docs/design/03-refinement-batch.md`（バッチ整形・
プロンプト構築の詳細）, `docs/design/13-speaker-diarization.md` / `docs/design/20-voiceprint-misassignment-mitigation.md`
（voiceprint 照合の信頼性についての既存知見。本設計が voiceprint に頼らない理由の根拠）。

本設計の要点は以下のとおり。

- **解決したい問題**: 会議アプリの音声が Mac の内蔵スピーカー等から物理的に再生されている場合、その音が
  マイクに回り込み、他の参加者の発言が `speaker: mic` セグメントとして書き起こされる。kikimi.md 6 章の
  前提（「diarization は不要（物理ソースで話者が確定するため）」）により mic セグメントは常に「自分の発言」
  として扱われるため、単なる表示上の重複ではなく **他者の発言が自分の発言として要約・Wiki export に
  混入する誤帰属**になる
- **採用方針**: 音響的な AEC（適応フィルタでシステム音声を参照信号としてマイク入力からキャンセルする）は
  見送る（2 章）。代わりに、**Refinement バッチが元々 mic/system を時系列マージして LLM に渡している
  既存構造**（`RefinementPromptBuilder`）を利用し、システムプロンプトに「近接する他ソースセグメントとの
  重複除去」ルールを 1 行追加する。判定・除外は、フィラー除去と全く同じ **`refined_text` 空文字**の
  仕組みをそのまま流用する（4 章）
- 併せて、漏れの発生条件（内蔵スピーカーからの音声出力）を検知し、イヤホン使用を促す UI バナーを出す
  予防策を追加する（5 章）。これは検出ロジックの誤り（false positive/negative）に一切依存しない、
  唯一の「根本原因を减らす」対策である
- **`transcript.jsonl` は一切変更しない**（追記のみの不変条件を維持）。除外は `refined.jsonl` 以降の
  レイヤでのみ行う（6 章）
- **`refined.jsonl` のフォーマットは変えずに、判定発火を推定するデバッグログを追加する**（4.6 章）。
  空文字だけでは「フィラー除去」と「漏れ聞こえ dedup」を区別できず、このままでは実戦での効果測定が
  できないため

---

## 1. 目的とスコープ

このドキュメントが担当するのは以下の対策のみ。

- **L1**: Refinement システムプロンプトへの重複除去ルール追加 + config toggle（4 章）
- **L2**: 出力デバイス種別（内蔵スピーカー/それ以外）の検知 + イヤホン推奨バナー（5 章）

**スコープ外**（明示的に見送り、または他ドキュメントの責務）:

| 関心事 | 扱い |
|---|---|
| 音響的な AEC（適応フィルタによるエコーキャンセル） | 見送り。理由は 2 章、再検討条件は 12 章 |
| mic 音声への voiceprint 照合の適用（「漏れた声が誰の声か」まで判定する） | 見送り。13 章 Open Question として留保（12 章） |
| システム音声内の話者分離そのもの（誰が話したかの識別） | `13-speaker-diarization.md` / `20-voiceprint-misassignment-mitigation.md` の責務。本設計はそこに触れない |
| Refinement バッチ処理全体の仕組み（バッチ切り出し・リトライ・fatal failure） | `03-refinement-batch.md` の責務。本設計はシステムプロンプト文言と config のみを追加する |

---

## 2. 問題の構造と AEC を見送る理由

### 2.1 漏れの経路

```
[会議アプリ] → (OS 音声出力) → [内蔵/外部スピーカー] --(空間を伝搬)--> [マイク]
                    │                                                    │
                    ▼                                                    ▼
            SystemAudioSource (Process Tap)                     MicrophoneSource
                    │                                                    │
                    ▼                                                    ▼
            speaker: system で transcript.jsonl に記録          speaker: mic で transcript.jsonl に記録
            （正: 発言者本人の音声）                              （誤: 実際は他者の発言だが「自分」扱い）
```

`01-audio-capture.md` 7 章の設計により、mic と system は**共通の host time クロック**に基づく
`elapsed`（→ `start_ms`/`end_ms`）を持つため、両セグメントの時刻はそのまま比較可能である
（diarization 不要という kikimi.md 6 章の前提と同じ根拠）。この「時刻軸が共通」という既存の性質が、
4 章の対策が追加のタイムスタンプ変換なしに成立する土台になる。

### 2.2 AEC を見送る理由

ユーザーとの事前検討で候補に挙がった「WebRTC AEC3 等を用いた適応フィルタによるエコーキャンセル」を
本設計では**採用しない**。理由:

1. **標準 API をそのまま使う経路がない**。Apple の Voice Processing I/O（`AVAudioEngine` の
   `setVoiceProcessingEnabled(true)`）による AEC は「同一 `AVAudioEngine` の出力ノードでレンダリングした
   音声」を参照信号とする設計である。Kikimi 自身は音声を出力せず、`SystemAudioSource`（Process Tap）は
   **他プロセスの出力を「聴取」するだけで「レンダリング」ではない**ため、この標準的な AEC 経路にそのまま
   乗せられない。ダミー出力ノード経由でタップ音声を「レンダリングしたことにする」トリックは技術的には
   存在するが、Apple 未公開の内部挙動に依存する上に、macOS バージョン間の互換性・音割れ/グリッチのリスクを
   新たに抱え込む
2. **自前実装のコストに見合わない**。汎用の適応フィルタ（NLMS/AEC3 系）を移植するには新規 C/C++
   ライブラリ依存に加え、スピーカー→マイクの伝搬遅延の推定・変動追従（部屋の反響・デバイス構成で
   変わり得る）が必要になる。ローカル個人アプリの規模に対して実装・検証コストが不釣り合いに大きい
3. **kikimi.md 7 章が既に確立している「LLM による意味判断で除外する」パターンが、実は今回の問題にも
   構造的にそのまま使える**（4.1 節で詳述）。フィラー除去と同じ仕組みを 1 行のプロンプト追加で
   転用できるなら、DSP 実装より先にそちらを試す方が費用対効果が高い
4. 将来の再検討条件は 12 章 Open Questions に記載する（L1 の実戦での検出精度が不十分と分かった場合の
   フォールバック）

---

## 3. 対策の全体像

| ID | 対策 | 効く場所 | 実装コスト |
|---|---|---|---|
| L1 | Refinement システムプロンプトへの重複除去ルール追加 | 検出・除外（起きてしまった後の対処） | 低（プロンプト文言 + config toggle のみ、新規コンポーネントなし） |
| L2 | 出力デバイス種別検知 + イヤホン推奨バナー | 予防（そもそも発生しにくくする） | 中（新規 CoreAudio コンポーネント 1 つ + banner 1 種） |
| （見送り） | 音響的 AEC | 除去そのもの | 高。本設計では実装しない（2 章） |

L1 と L2 は独立に効く。L2 （イヤホン使用）が徹底されれば漏れそのものが物理的に起きなくなるが、
ユーザーがスピーカーで会議に参加する運用は排除できないため、L1 の事後検出は L2 とは無関係に必要になる。

---

## 4. L1: Refinement プロンプト拡張

### 4.1 なぜこの構造が使えるか

`RefinementPromptBuilder.buildUserPrompt`（`Kikimi/Refinement/RefinementPromptBuilder.swift` L73-96）は、
`contextSegments`（直前の文脈）・`batchSegments`（今回整形する対象）の両方を **`start_ms` 昇順で
mic/system を時系列マージ**した上で、`formatLine(id:speaker:text:)`（同ファイル L98-101）により
**`seg_XXXXX (mic): ...` / `seg_XXXXX (system): ...` という source タグ付き**で LLM に渡している。

つまり LLM は現状でも、あるバッチを整形する時点で「直前の文脈」に**対岸ソースの発言をソース種別つきで
既に見た状態**にある。これは 13 章の diarization とは無関係に、`kikimi.md` 7 章の設計が意図せず
（本来はキャッシュ効率や文脈把握のための設計だった）用意していた土台であり、**新規コンポーネントを
足さずシステムプロンプトに判定ルールを 1 行追加するだけ**で「近接する時刻の対岸セグメントとの重複」を
LLM に判定させられる。

除外の実行機構も新設不要。`RefinementValidator.validate`（`Kikimi/Refinement/RefinementValidator.swift`
L18-21, L77 付近）は LLM が返した `refinedText` の空文字を**正常系**として素通りさせ（`error: nil`）、
UI 側は `TranscriptRowState`（`Kikimi/ViewModels/TranscriptRowList.swift` の `isDroppedByRefinement`。
実際に描画する `Kikimi/Views/MeetingWorkspace/TranscriptTabView.swift` / `CompactRecordingBarView.swift`
はこの `ViewModels` 側の型を参照しているだけで、`Views/` 配下に同名の型はない）で Transcript タブから
非表示にし、`RefinementPromptBuilder.buildUserPrompt` は空文字判定済みセグメントを後続バッチの
「直前の文脈」ブロックからも除外する（L78 の `filter { $0.refinedText?.isEmpty != true }`）。
Wiki export（kikimi.md 11 章）も同じ空文字フィルタで除外される。**この一本の既存経路をそのまま
「漏れ聞こえ」判定にも使う**ため、除外側のコードは 1 行も変更しない。

### 4.2 システムプロンプトの変更

`RefinementPromptBuilder.buildSystemPrompt(context:)`（同ファイル L35-57）の【整形ルール】に
以下を追加する。

```
- (mic) セグメントの内容が、直前の文脈または今回のバッチ内にある近い時刻の (system) セグメントと
  ほぼ同じ内容の場合、スピーカーの音がマイクに回り込んで二重に書き起こされたものとみなし、その
  (mic) セグメントの refined_text を空文字にする（対応する (system) セグメント側は変更しない）
```

設計判断:

- **判定基準は意図的に厳密な文字列一致にしない**。mic 側はスピーカー→空間→マイクという劣化した経路で
  再度 STT されるため、system 側の書き起こしと表記・言い回しが完全一致するとは限らない（例:
  「そうですね、了解しました」→「了解しました」のような欠落）。「ほぼ同じ内容」という緩い自然言語の
  指示にして、LLM の意味理解に委ねる。厳密一致にすると再現率が下がり、緩すぎる基準にすると誤って
  本人の発言を消す（4.5 節）。この境界の実測チューニングは 12 章 Open Question とする
- **常に (mic) 側だけを削除し、(system) 側は変更しない**。system 側は話者分離（13 章）の入力であり
  書き起こしの正として保全する必要がある。mic 側は元々「自分の発言」という前提のみで個別の話者を
  持たないため、誤検知時の実害（＝本人の発言が消える）はフィラー除去と同種の、既に許容されている
  リスクの延長線上にある
- **同一ソース内の重複（mic 同士・system 同士）は対象外**。物理的な回り込みは常に system → mic の
  一方向であり、同一ソース内の重複はそもそも想定される事象ではない（対象になる誤爆を避けるため
  明示的に対象範囲を書く）

### 4.3 config

```yaml
refinement:
  dedup_system_leak_segments: true   # 新設。既定 true
```

- `AppConfig` の `RefinementConfig`（`Kikimi/Config/AppConfig.swift` L9-）に
  `dedupSystemLeakSegments: Bool`（CodingKey: `dedup_system_leak_segments`、既定 `true`、防御的 decode）
  を追加する
- `RefinementPromptBuilder.buildSystemPrompt(context:)` に `dedupSystemLeakSegments: Bool = true`
  引数を追加し、`false` のときは 4.2 節のルール行を含めずにシステムプロンプトを組み立てる
  （システムプロンプトはキャッシュヒットのため完全固定という 7 章の原則は維持: toggle の値自体は
  セッション開始時に固定され、Recording 中に変わらない前提 — `context_refresh_batches` によるキャッシュ
  更新戦略とは無関係な、起動時固定の設定値であるため、キャッシュヒット率に悪影響を与えない）
- **`diarization.enabled` とは独立**。mic と system の両方を録っている限りこの問題は物理的に起こり得る
  ため、diarization（system 内の話者分離）の有効/無効に関係なく効かせる
- **system 音声が縮退している場合（`activeSources == {mic}`、`01-audio-capture.md` 9 章 失敗モード #3）
  の扱いに追加の分岐は不要**。バッチ内・直前文脈内に `(system)` セグメントが 1 つも存在しなければ
  LLM が比較対象を持たないため、ルールは自然に no-op になる

### 4.4 直前文脈のウィンドウに関する既知の限界

既存の「直前 `context_segments` セグメント」窓（既定 3、`kikimi.md` 7 章）およびバッチ内相互参照
（既定バッチサイズ 10・5 秒タイムアウト、`03-refinement-batch.md`）に、漏れ元の system セグメントが
収まらないケース（長い発言・mic 側のセグメント確定が大きく遅れた場合等）では、対岸セグメントが
LLM に見えず判定できない。この場合、誤帰属は検出されずに残存する。この限界は受容し、実戦
（kikimi.md 15 章 Phase 4）での発生頻度を見て `context_segments` のチューニングや別対策を検討する
（12 章 Open Questions）。

### 4.5 誤検知（false positive）のリスクと受容

「本人が相槌等で他者の発言と時間的に重なる短い発言をした」ケースで、内容がたまたま類似していると
誤って削除され得る（例: system 側「了解です」とほぼ同時に本人も「了解です」と発言した場合）。これは
人間でも音声なしでは判別が難しい曖昧なケースであり、フィラー除去が既に受け入れている「LLM の意味判断は
完璧ではない」という前提の延長として許容する。`transcript.jsonl` の raw テキストは 6 章の通り一切
消えないため、誤検知が起きても元の書き起こし自体は失われない。

### 4.6 可観測性: 判定発火を推定するデバッグログ

4.5 節と 12 章はいずれも「実戦での誤検知・検出漏れの頻度を計測してチューニングする」ことを前提にしているが、
現状の設計には **その計測を可能にする仕組みが何もない**。`refined_text` の空文字は「フィラー除去」と
「漏れ聞こえ dedup」のどちらが発火した結果なのかを区別できない一枚岩の signal であり、`RefinementResponse`
にも `refined.jsonl`（`RefinedSegment`）にも削除理由を示すフィールドは無く、専用のログ出力も無い。この
ままでは 12 章の評価計画は実行不能なので、最低限のデバッグログを追加する。

- **`refined.jsonl` のフォーマットは変更しない**（5 章の不変条件を維持）。LLM のレスポンス schema にも
  理由フィールドは追加しない（プロンプト・schema をこれ以上複雑にしない、7 章の「常に固定・キャッシュ
  ヒット優先」方針を崩さないため）
- 削除理由を LLM から直接得られない代わりに、**「LLM がそのバッチを整形する際に実際に目にしていた
  system セグメントの集合」に対する事後的な time-proximity ヒューリスティック**で推定する。判定対象は
  `RefinementValidator.validate` が返した `RefinedSegment` のうち `speaker == .mic && refinedText == ""`
  のもの（4.2 節の設計により、このルールが対象にするのは常に mic 側の空文字化のみ）
  - 「LLM が見ていた system セグメント」= その呼び出しの `contextSegments`（`processBatch(_:)` が
    `RefinementPromptBuilder.buildUserPrompt` に渡した `Array(contextHistory.suffix(config.contextSegments))`,
    `RefinementQueue+BatchProcessing.swift` L19）と `batch` 自身のうち `speaker == .system` のもの
  - この集合に 1 件でも存在すれば `候補: 漏れ聞こえ dedup`、1 件も無ければ `候補: フィラー除去` として
    debug ログに出す。時間差の閾値は新設しない（LLM に見えていた窓と全く同じ集合を使うことで、4.4 節が
    挙げる「文脈窓に収まらない漏れは検出できない」という限界と評価対象を一致させる）
- **実装位置**: `RefinementQueue+BatchProcessing.swift` の `processBatch(_:)` および `handleFailure(...)`
  のリトライ成功パス（いずれも `RefinementValidator.validate(...)` の直後、`mergeIfPossible` で
  `RefinedSegment` が結合される前）に共通の private helper（例: `logLeakDedupCandidates(batch:contextSegments:validated:)`）
  を追加して呼び出す。結合前の 1:1 な `segments`（`batch` と同じ並び）を使うことで、`RefinementMerge`
  が複数セグメントを1ユニットに結合するケース（15.2.3 節）でも判定対象を取りこぼさない
- **ログ内容（例、`logger.debug`）**:
  - 候補あり: `"refinement leak-dedup candidate: seg_00042 (mic) refined to empty; nearby system segment(s) in this batch's LLM context: seg_00040, seg_00041"`
  - 候補なし: `"refinement leak-dedup candidate: seg_00042 (mic) refined to empty; no system segment visible to this batch (likely filler removal)"`
  - ログレベルは `debug`（`CLAUDE.md` Logging Rules の「Debug info → debug」に従う。既存の `warning`/`error`
    ログとは独立したカテゴリの情報であり、通常運用でノイズにならない）。`log stream --predicate
    'subsystem == "io.github.uphy.Kikimi" && category == "RefinementQueue"' --level debug` で
    実戦セッション中に「候補: 漏れ聞こえ」件数と「候補: フィラー」件数を数えられるようにする
- **この推定はあくまで近似であり、真の発火理由の ground truth ではない**ことを明記する。相槌が
  たまたま対岸セグメントと時間的に近接していただけの純粋なフィラー除去も「候補: 漏れ聞こえ」に
  誤ってカウントされ得るし、逆に 4.4 節の限界（文脈窓に対岸セグメントが収まらない）で検出漏れした
  真の漏れ聞こえは、この定義上そもそも空文字にならないため計測対象にすら現れない。12 章の実測は
  「このログが示す候補件数の**傾向**」を見るためのものであり、厳密な精度測定ではない

---

## 5. L2: 出力デバイス種別検知とイヤホン推奨バナー

### 5.1 設計方針

新規コンポーネント `OutputRouteMonitor`（`Kikimi/AudioCapture/OutputRouteMonitor.swift` 想定）を、
`SystemAudioSource.swift` が既に使っている CoreAudio の `AudioObjectGetPropertyData` パターン
（同ファイル L295 以降の `resolveExcludedProcesses`/`processObjectIDs` 等）を踏襲して実装する。

- `kAudioHardwarePropertyDefaultOutputDevice`（`kAudioObjectSystemObject` 起点）でデフォルト出力
  デバイスの `AudioObjectID` を取得し、そのデバイスの `kAudioDevicePropertyTransportType` を読む
- 判定は pure function `OutputRouteClassification.classify(transportType: UInt32) -> OutputRouteClassification`
  （`.builtInSpeaker` / `.other`）に切り出す（テスト容易性、8 章）。`kAudioDeviceTransportTypeBuiltIn`
  のみ `.builtInSpeaker`、それ以外（Bluetooth/USB/HDMI/AirPlay 等）はすべて `.other` とする**単純な
  二値判定**にとどめる
- **既知の限界**: 会議室の Bluetooth スピーカーのように、実体はスピーカーでもイヤホン/ヘッドホンでは
  ない外部出力デバイスは `.other` に分類され、バナーが出ない（false negative）。これは意図的に
  **安全側（バナーを出さない方向）に倒す**判断とする。「イヤホンを使っているのに毎回バナーが出る」
  ノイズの方が「稀な外部スピーカー構成でバナーが出ない」ことより実害が大きいと判断した
- **検知タイミング（polling 方式に修正）**: Recording 突入時に 1 回評価し、以降は **`DispatchSource`
  タイマーによる定期ポーリング**（既定 10 秒間隔）で再評価する。Paused/Ended ではタイマーを止め、
  Recording 再開で再始動する（`RealtimeDiarizationCoordinator` 等、他のセッションスコープ actor と
  同じライフサイクルに合わせる）
  - **listener 方式（`AudioObjectAddPropertyListener` で `kAudioHardwarePropertyDefaultOutputDevice`
    等を購読）は採用しない**。当初案では「`SystemAudioSource.swift` L408 周辺のコメントが listener
    方式を既定路線としている」ことを踏襲する設計だったが、これは誤読だった。実際の
    `SystemAudioSource.swift` L403-421（`startStallTimer()` の doc comment）は逆に、**「単一の
    timeout ベースの stall 検出の方が、`kAudioObjectSystemObject` の device-changed 通知を購読するより、
    デフォルトデバイス変更・aggregate device/tap 破棄など様々な原因を漏れなく捕捉できる」という理由で
    意図的に polling（タイマー）を選び、listener 方式を見送っている**（=この設計が引用しようとした
    「既存判断」は実際には正反対の結論だった）。加えて `Kikimi/AudioCapture/` 配下にも Chirami 参照実装
    （ローカル参照専用の並列クローン）にも `AudioObjectAddPropertyListener` /
    `kAudioHardwarePropertyDefaultOutputDevice` / `kAudioDevicePropertyTransportType` の使用例は
    一件も無い（grep で確認済み）。つまり `OutputRouteMonitor` は「既存パターンの踏襲」ではなく
    Kikimi 内・Chirami 参照実装のどちらにも前例のない新規 CoreAudio API 面であり、唯一の類似事例
    （`SystemAudioSource` の stall 検出）が明示的に polling を選んだ判断根拠を持つ以上、本設計も
    **`SystemAudioSource.startStallTimer()` と同じ `DispatchSource.makeTimerSource` パターンに倣った
    polling 方式**を採用する。10 秒間隔としたのは、物理的なデバイス変更はユーザーの離散的な操作
    （イヤホン接続/取り外し・出力先切り替え）であり、`SystemAudioSource` のストール検出のような
    秒単位のリアルタイム性は不要なため（間隔は実戦での体感を見て 12 章 Open Questions でチューニング
    対象にする）

### 5.2 UI

`WorkspaceBanner`（`Kikimi/ViewModels/MeetingWorkspaceTypes.swift` L183-）に新規ケースを追加する。

```swift
/// system audio capture is enabled and the default output device is built-in speakers: acoustic
/// leakage into the mic is likely (24-system-audio-leak-mitigation.md).
case builtInSpeakerOutputDetected
```

文言案:「内蔵スピーカーで会議音声を再生していると、マイクが音を拾って二重に書き起こされることが
あります。イヤホン/ヘッドホンの使用をお勧めします」

- 出力デバイスが `.builtInSpeaker` になった時点で `banners` へ追加/`.other` に変わった時点または録音が
  Recording でなくなった時点で `removeAll(where:)` により自動的に取り除く、という**発火・除去自体**は
  他の banner と同じ `banners: [WorkspaceBanner]` パターン（`MeetingWorkspaceViewModel+AudioInput.swift`
  L152, L169 等）に従う
- **ただし「ユーザーが閉じたら同一セッション中は再表示しない」という永続 dismiss 要件は、既存の banner
  パターンには存在しない新規の状態管理として本設計内で明示する**。既存の banner
  （`systemAudioUnavailable`/`fileWriteFailed`/`recordingStartFailed` 等、`MeetingWorkspaceViewModel+
  AudioInput.swift` L164-174・L151-153、`+RecordingInternals.swift` L171-175）はすべて「条件が
  再発火したら `removeAll(where:)` + `append` を無条件に繰り返す」だけの作りで、一度閉じたら二度と
  出さないという永続 dismiss 状態を保持する仕組みを 1 つも持たない。`06-ui-panels.md` にも dismiss の
  記述自体が存在しない（grep で該当なし）。この `builtInSpeakerOutputDetected` は「閉じたら
  Recording 中はデバイス変更のたびに再発火し得る」という**既存の再評価パターンと衝突する要件を
  初めて持つ banner**であるため、既存パターンへの「踏襲」では要件を満たせない。したがって:
  - `MeetingWorkspaceViewModel` に `private var dismissedBuiltInSpeakerBanner: Bool = false`
    （セッションウィンドウ＝ ViewModel インスタンスの生存期間中のみ有効。ディスクへの永続化はしない
    — 「同一セッション中」はウィンドウが開いている間で十分であり、`06-ui-panels.md` の他の一時的な
    UI state と同様アプリ再起動やウィンドウ再オープンでリセットされてよい）を新設する
  - `MeetingWorkspaceView.swift` の banner dismiss ボタン（現状 `viewModel.banners.removeAll { $0.id ==
    banner.id }` を直接呼ぶだけ、L274）から `builtInSpeakerOutputDetected` を閉じた場合だけ、
    `viewModel.dismissBuiltInSpeakerBanner()` のような専用メソッド経由で `banners` からの除去に加えて
    `dismissedBuiltInSpeakerBanner = true` を立てる
  - `OutputRouteMonitor` の再評価結果を受け取る箇所（`presentSystemAudioUnavailableBanner` 等と同様の
    `MeetingWorkspaceViewModel` 側ハンドラを新設）は、`.builtInSpeaker` と判定しても
    `dismissedBuiltInSpeakerBanner == true` の間は `banners.append` をスキップする。これにより
    「デフォルト出力デバイス変更のたびに再評価して `banners.append` する」という §5.1 のポーリング駆動
    再評価と、「閉じたら同一セッション中は二度と出さない」という要件が両立する
  - `dismissedBuiltInSpeakerBanner` は Paused/Ended で `false` に戻さない（「同一セッション中」は
    録音の一時停止・再開を跨いで有効という意図。会議が終了して初めて — つまり ViewModel が破棄されて
    次に開いたときに — リセットされる）
- system 音声が無効/縮退中（`activeSources == {mic}`）はそもそも漏れの「二重書き起こし」が起きない
  （比較対象の system セグメントが存在しない）ため、バナー自体を出さない

### 5.3 config

```yaml
audio:
  suggest_headphones_on_builtin_speaker: true   # 新設。既定 true
```

- **`AppConfig` に既存の「audio 設定」は存在しないため、新設が必要**。`Kikimi/Config/AppConfig.swift`
  の `KikimiConfigData` は `diarization`/`refinement`/`llm`/`stt`/`summary`/`watchers`/`export` の
  7 セクションのみを実装しており、`audio` セクションに対応する `Codable` 構造体は無い。
  `01-audio-capture.md` 11 章の `audio.format`/`audio.sample_rate`/`audio.channels` は
  `KikimiConfigData` を経由せず、`AudioCaptureConfig` を組み立てる**手前の設定読み込み層**
  （`07-session-store.md` 担当）が config.yaml を直接消費する別経路であることが同章で明記されている。
  この経路は `WavFileWriter`/`AudioCapture` 向けの値（サンプルレート等）専用であり、
  `OutputRouteMonitor`（本設計 5.1 節、`AudioCapture` とは無関係な新規コンポーネント）が読む
  bool トグルを流し込む先として適切ではない
  - したがって本設計では、`suggestHeadphonesOnBuiltInSpeaker: Bool`（CodingKey:
    `suggest_headphones_on_builtin_speaker`、既定 `true`、防御的 decode）を持つ新規
    `AudioConfig: Codable, Equatable, Sendable` 構造体を、`DiarizationConfig`/`RefinementConfig` と
    同じ「セクション 1 つにつき構造体 1 つ」のパターンで新設し、`KikimiConfigData` に `var audio:
    AudioConfig` フィールドとして追加する（`init`/カスタム `init(from:)` の両方に他セクションと同様の
    デフォルトフォールバックを実装）
  - `OutputRouteMonitor` はこの `AppConfig.shared.data.audio.suggestHeadphonesOnBuiltInSpeaker` を
    Recording 開始時に読み、`false` なら `OutputRouteMonitor` 自体を起動しない
  - 将来 `audio.format`/`audio.sample_rate`/`audio.channels`（`01-audio-capture.md` 11 章）も
    `KikimiConfigData` 側へ寄せる場合は、この `AudioConfig` 構造体を拡張先として使える

---

## 6. `transcript.jsonl` / `refined.jsonl` 不変条件との整合性

- **`transcript.jsonl` は一切変更しない**。L1 は `refined.jsonl` の `refined_text` を空文字にするだけで、
  `raw_text` には mic 側の元テキストがそのまま残る。これは kikimi.md 5 章の「transcript.jsonl は追記のみ、
  決して rewrite しない」という不変条件をそもそも触らない設計であることの再確認
- kikimi.md 11 章の Wiki export 規則（「refined_text が空文字（意味なしと判定され削除されたセグメント）
  の行は export に含めない」）は既存のフィラー除外と全く同じ経路を通るため、**追加の分岐は不要**
- L2 は UI バナーのみで、いかなるファイル形式にも影響しない

---

## 7. 失敗モード

| # | 状況 | 挙動 | ログレベル | ユーザー可視性 |
|---|---|---|---|---|
| 1 | L1 のプロンプトルールが誤って本人の発言を削除する（4.5 節、false positive） | `raw_text` は保全されるため書き起こし自体は失われない。Transcript タブでは非表示、サマリ/Wiki export には出ない | — （既存のフィラー除外と同じ扱いのため専用ログなし） | 通常は気付かれない（フィラー除去と区別不能な UX）。実戦での頻度が高ければ 12 章の再検討対象 |
| 2 | L1 が検出漏れする（4.4 節、文脈窓に対岸セグメントが収まらない） | 誤帰属が残存する（本設計導入前と同じ状態） | — | サマリ・Wiki export に他者発言が「自分」として残る |
| 3 | Refinement LLM 呼び出し自体が失敗する | 既存の `RefinementValidator`/`RefinementQueue` の null フォールバック規則がそのまま適用される（本設計での変更なし） | 既存どおり | 既存どおり |
| 4 | `OutputRouteMonitor` の CoreAudio API 呼び出しが失敗する（デバイス列挙エラー等） | バナーを出さないだけ。録音は継続（kikimi.md 8.5 章 best-effort 原則） | `.warning` | 非表示（内部的なフォールバック） |
| 5 | 外部スピーカー構成が `.other` に誤分類される（5.1 節、false negative） | バナーが出ない。L1 の事後検出のみが働く | — | バナーが出ないこと自体は非表示（気付かれない） |

録音・STT・セッション確定処理をブロックする経路は一切追加しない。

---

## 8. テスト容易性

### レイヤ1（単体テスト, swift-testing/XCTest）

- `RefinementPromptBuilder.buildSystemPrompt(context:dedupSystemLeakSegments:)`: `true`/`false` で
  4.2 節のルール行の有無が切り替わることを検証（文字列包含チェック）
- `RefinementValidator` は変更しないため既存テストがそのままカバーする
- `OutputRouteClassification.classify(transportType:)`: `kAudioDeviceTransportTypeBuiltIn` →
  `.builtInSpeaker`、Bluetooth/USB/HDMI 等の値 → `.other` を固定値で検証（実デバイス非依存の pure
  function）
- `RefinementConfig.dedupSystemLeakSegments` / 新設 `AudioConfig.suggestHeadphonesOnBuiltInSpeaker`
  の既定値・decode（キー欠落時に `true` になること）

### レイヤ2（`kikimi-verify` skill）

**`KIKIMI_TEST_INPUT` で自動検証できるのは「toggle の配線が正しいこと」だけであり、4.2 節が本来の
難所として挙げている「ほぼ同じ内容（劣化した言い回し）」の判定精度はこの自動テストでは検証されない。**
以下の点を明記する。

- `01-audio-capture.md` 10 章の通り、`KIKIMI_TEST_INPUT` は mic 用・system 用それぞれ独立した
  `TestFileAudioSource` に**バイト単位で完全に同一の音声ファイル**を `source: .mic` / `source: .system`
  としてタグ付けして供給する設計になっている。つまりこのテストモードで mic/system に渡る書き起こしは
  常に**完全一致**であり、4.2 節が「厳密な文字列一致にしない」理由として挙げている「スピーカー→空間→
  マイクという劣化した経路で再度 STT され、表記・言い回しが完全一致するとは限らない」という本来の
  難所を一切再現しない。このテストで mic 側の `refined_text` が空文字になったとしても、それが
  「ほぼ同じ内容」の緩い自然言語判定が正しく機能した証拠にはならず、単に「システムプロンプトの
  ルール行が実際にプロンプトへ載っている／`dedup_system_leak_segments: false` でロード時に外れる」
  という **toggle の配線検証**にしかならない。判定精度（誤検知・検出漏れの実際の頻度）は 12 章が
  言う通り実戦（kikimi.md 15 章 Phase 4）でしか測れず、自動テストで代替できるという主張はしない
- **さらに、この配線検証すら `kikimi-verify` の既定フロー（`KIKIMI_STUB_LLM=1`）のままでは成立しない。**
  `Kikimi/LLM/LLMStubProvider.swift` の `RefinementEchoStub.generateResponseJSON` は、対象セグメントを
  常に `"[stub] " + rawText` として返すか、`rawText` が `"えーと"` を含む/空文字の場合のみ
  `refined_text: ""` にするだけで、**mic/system 間の内容比較ロジックを一切持たない**（4.2 節の
  「近い時刻の対岸セグメントとほぼ同じ内容か」という意味判断は Haiku 実呼び出しでしか再現できず、
  スタブに実装しても「本物の判定をしているように見えて実は固定ロジック」という別の誤解を生むだけ
  なので、スタブへの再現は行わない）。`~/.claude/skills/kikimi-verify/SKILL.md` および `CLAUDE.md` の
  記載通り、`kikimi-verify` のレイヤ2検証は既定で `KIKIMI_STUB_LLM=1` を使う。したがって以下の手順を
  この既定フローのまま実行しても、mic 側の `refined_text` は常に `"[stub] " + rawText`（非空）のままで
  変化せず、**L1 が機能しているかどうかを一切検証できない**（誤って「動いていない」と判断するか、
  検証していないことに気づかないまま完了扱いにするリスクがある）
- **したがって、下記手順は `KIKIMI_STUB_LLM` を無効化した状態（＝実際の Claude API 呼び出しが発生し、
  課金を伴う）でのみ実行する。** `kikimi-verify` を使う際は、この設計の効果確認に限り
  `KIKIMI_STUB_LLM` を明示的に外す（未設定にする）よう手順を修正すること
- 手順（`KIKIMI_STUB_LLM` 無効時のみ）: `KIKIMI_TEST_INPUT` で録音 → 数秒待機 → 停止 → `refined.jsonl`
  を読み、`speaker: mic` のセグメントの `refined_text` が空文字になっていること（かつ対応する
  `speaker: system` セグメントの `refined_text` は非空であること）を確認する。これは**toggle の配線が
  実際に効いていること**（プロンプトルールが載っている・LLM 呼び出しが実行されている）の確認であり、
  「ほぼ同じ内容」判定の精度検証ではないことを実行者は認識しておく
- `dedup_system_leak_segments: false` で同じ手順を流し、mic 側が空文字にならないことも併せて確認する
  （toggle の効果確認）
- L2（`OutputRouteMonitor`）は CI/自動操作環境では実デバイス構成に依存するため、
  「API 呼び出しが失敗してもクラッシュせず起動できること」のみを自動確認対象とし、実際の
  内蔵スピーカー検知・バナー表示は手動確認項目とする（`kikimi-verify` の手動チェックリストに追加）

---

## 9. config.yaml（変更まとめ）

```yaml
refinement:
  dedup_system_leak_segments: true   # 新設（4.3 節）。既定 true

audio:
  suggest_headphones_on_builtin_speaker: true   # 新設（5.3 節）。既定 true
```

---

## 10. 他ドキュメントとの境界

| 相手 | 契約 |
|---|---|
| `03-refinement-batch.md` | システムプロンプトの構築ロジック自体（バッチ切り出し・リトライ等）はそちらの責務。本設計は `RefinementPromptBuilder.buildSystemPrompt` に渡す文言と bool 引数を追加するのみ |
| `01-audio-capture.md` | `OutputRouteMonitor` は `AudioObjectGetPropertyData` の呼び出しパターン、および `SystemAudioSource.startStallTimer()` の `DispatchSource` タイマー（polling）パターンを踏襲する新規コンポーネントとして `Kikimi/AudioCapture/` に置く（5.1 節）。`KIKIMI_TEST_INPUT` の mic/system 同一音声供給という既存仕様（10 章）を L1 のテスト配線確認にそのまま利用する（変更なし。ただし判定精度そのものはこのテストでは検証できない — 8 章参照） |
| `06-ui-panels.md` | `WorkspaceBanner.builtInSpeakerOutputDetected` の追加・自動除去は既存 banner 群と同じ UI 実装パターンに従う。ただし**永続 dismiss 状態（5.2 節の `dismissedBuiltInSpeakerBanner`）は既存パターンに無い新規の状態管理であり、本設計内で仕様を確定させる**（`06-ui-panels.md` 側に委譲しない） |
| `13-speaker-diarization.md` / `20-voiceprint-misassignment-mitigation.md` | 本設計はこれらの voiceprint 照合ロジックに一切変更を加えない。mic 側への voiceprint 適用は 12 章の Open Question として留保するのみ |

---

## 11. 実装フェーズ分割

| モジュール | 内容 | 依存 |
|---|---|---|
| **V1** | L1: システムプロンプトのルール追加・`RefinementPromptBuilder` の bool 引数・`RefinementConfig.dedupSystemLeakSegments` config | なし。最も低コストで即着手可能 |
| **V2** | L2: `OutputRouteMonitor` + `OutputRouteClassification`（pure）+ `WorkspaceBanner.builtInSpeakerOutputDetected` + audio config | V1 と独立 |

V1・V2 は並行実装可能。V1 を先に着手し、`kikimi-verify` の `KIKIMI_TEST_INPUT` 手順（8 章）で効果を
確認してから V2 に着手する順序を推奨する（V1 の方が既存インフラの再利用度が高く、実装・検証が速い）。

---

## 12. Open Questions（実測後に判断する事項）

- **「ほぼ同じ内容」判定の精度**（4.2 節）は Haiku での実測が必要。実戦（kikimi.md 15 章 Phase 4、
  実会議 3 本以上）で誤検知（4.5 節）・検出漏れ（4.4 節）の頻度を計測し、プロンプト文言の調整
  （具体例の追加等）や `context_segments` の引き上げを検討する
- **AEC の再検討条件**（2 章）: 上記実測で L1 の検出漏れ・誤検知の頻度が実用に耐えないと判明した場合、
  音響的アプローチ（2.2 節で見送った経路）または mic 側への voiceprint 照合拡張（次項）を再検討する
- **mic 側への voiceprint 照合の拡張**: 調査の結果、`VoiceprintExtractor.extractEmbedding(from:)`
  （`Kikimi/Diarization/VoiceprintExtractor.swift`）はソース非依存（16kHz Float32 を渡せば動作する）
  ため、mic セグメントの音声にも技術的には適用可能（「漏れた声が既知の他参加者の声紋と一致するか」を
  判定材料に加える）。ただし `20-voiceprint-misassignment-mitigation.md` が示す通り、**単体の
  voiceprint 照合には既に「未登録話者を誤って既存話者に割り当てる」という構造的な精度課題があり**、
  同じ脆弱性を新しい判定用途（漏れ検出）に持ち込むことになる。加えて `RealtimeDiarizationCoordinator`
  は現状 system 音声専用に設計されており、mic 用の呼び出し経路の新設・「イベント駆動で会議序盤に
  数回」という低頻度前提が崩れるコスト増（system 側は enrollment 目的の数回のみだが、mic 側は
  「他人発言候補」セグメントごとに抽出が必要になり得る）も伴う。**L1 の実測精度が不十分と判明した
  場合にのみ**、この方式を代替・補完案として再検討する
- **外部スピーカー構成の誤分類頻度**（5.1 節の false negative）: `.other` 判定により Bluetooth/USB
  スピーカー使用時にバナーが出ない実害がどの程度あるか、実戦で頻度を見て転送タイプ判定をより細かく
  （デバイス名文字列マッチ等のヒューリスティック追加）するか判断する
- **`dedup_system_leak_segments` を diarization 同様セッション途中で切り替え可能にするか**: 4.3 節では
  起動時固定としたが、Recording 中にユーザーが「誤検知が多い」と気付いて即座に無効化したいニーズが
  実戦で出るか様子を見る
