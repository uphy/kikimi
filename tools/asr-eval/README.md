# ASR 評価セット（二段目バッチデコードのモデル比較）

Kikimi の 2 段目（確定セグメントのバッチ再デコード、`docs/design/33-meeting-two-pass-decode.md`）で
使うモデルを、**実際に録音した会議音声**で比較するための評価セット。

外部ベンチの公表値は、朗読音声（JSUT 等）と自然会話とで**順位が反転する**。会議は後者に近いが、
公表値の比較表には Kikimi が日本語で実際に使っているモデル（`parakeet-0.6b-ja`）が載っていない。
手元の音声で測らないと決められない、というのがこのセットを作った理由。

## 置き場

| 何 | どこ | git |
|---|---|---|
| スクリプト・ハーネス | `tools/asr-eval/`, `KikimiTests/Stt/AsrEval*.swift` | 管理下 |
| クリップ・書き起こし・スコア | `~/.local/state/kikimi/asr-eval/` | **管理外**（実会議の音声と発話内容のため） |

評価データを共有・添付するときは中身を確認すること。実在の会議の発話がそのまま入っている。

## 手順

```bash
# 1. 録音済みセッションから評価クリップを切り出す（既定 24 本 / 約 10 分）
python3 tools/asr-eval/make_clips.py

# 2. 各モデルを回す（順不同・追加可能）
tools/asr-eval/runners/tdtja.sh          # 現行ベースライン
tools/asr-eval/runners/parakeet_v3.sh    # 多言語 Parakeet（ja 以外に振れたときの実力）
tools/asr-eval/runners/cohere.sh         # Cohere Transcribe（FluidAudio 同梱）
tools/asr-eval/runners/whisperkit.sh     # WhisperKit large-v3-turbo
tools/asr-eval/runners/qwen3_draft.sh    # 比較対象外。reference の下書き専用（下記）

# 3. reference 確定シートを作る → 音声を聞いて直す → 反映
python3 tools/asr-eval/review.py --build --draft qwen3_draft
open ~/.local/state/kikimi/asr-eval/review.md
python3 tools/asr-eval/review.py --apply

# 4. 採点
python3 tools/asr-eval/score.py
```

## 現在の状態（2026-08-02 時点）

クリップ 24 本 / 582 秒（mic 6・system 18、8 セッション横断）。全モデルのデコードは完了済みで、
**reference の人手確定だけが残っている**（`review.md`）。CER は確定後に `score.py` で出る。

速度は先に測れたので載せる。M4 Pro / 48GB、モデルロードとウォームアップを除いた実推論のみ。

| モデル | RTF | 備考 |
|---|---|---|
| `tdtja`（現行） | 0.0081 | 582 秒を 4.7 秒 |
| `parakeet_v3` | 0.0086 | 日本語では出力が崩壊（下記） |
| `qwen3_draft` | 0.0442 | MLX/GPU。比較対象外の下書き専用 |
| `cohere` | 0.3281 | 初回推論は CoreML の特殊化で 87 秒かかる（ウォームアップ済みの値） |
| `whisperkit` | 0.6463 | 582 秒を 376 秒 |

**この差は採用判断に直接効く。** 会議パイプラインはセグメント確定のたびに再デコードし、mic と
system の 2 ソースが同じ ANE を共有する（design 33 MT5）。RTF 0.65 のモデルは実効 1.3 相当になり、
確定テキストがライブ表示に追いつかなくなる可能性がある。CER がどう出ても、WhisperKit を採用する
なら「確定を遅らせない」設計が別途要る。

`parakeet_v3` は日本語音声をローマ字と多言語の混合として出力し、事実上使いものにならなかった
（例: `What's going on this? Ah, so so none this yeah.`）。外部ベンチで報告されている CER 174% と
一致する。**現行の `ja → tdtJa` 分岐は正しい**という確認になった。

Cohere の 108 トークン上限は 30 秒クリップでは 1 本も当たらなかった（`token_capped_clips: 0/24`、
最大 92 トークン）。ただし Kikimi の実際の窓は最大 120 秒なので、**長い窓では確実に当たる**。
Cohere を採用するなら窓を 30 秒前後に切り直す設計変更がセットで要る。

## 設計上の判断

**クリップは 30 秒以下・セグメント境界で切る。**
全候補が 30 秒を *単一窓* で処理できる。Cohere は 35 秒ハードキャップ、Whisper の窓は 30 秒、
Kikimi の `BatchAsrDecoder` は 15 秒超で自前分割する。全モデルのチャンク閾値の下に収めることで、
比較の対象が「音響モデルの実力」になる。超えると「誰のチャンク結合ヒューリスティクスが優秀か」の
比較になり、知りたいことがぼやける。

**mic は本数を固定で確保する。**
録音済みセッションは system 音声に大きく偏る（会議とはそういうもの）。比例配分にすると mic が
1〜2 本になり、mic 側の劣化が検出できない。mic は近接した単一話者、system は圧縮された遠端の
混合音で、別の問題として扱う必要がある。

**主指標は句読点を落とした CER（`cer_norm`）。**
候補モデルは句読点の扱いが設計上バラバラで（Parakeet TDT Japanese は付けない、Whisper と Cohere は
付ける）、しかも Kikimi は後段の LLM 整形で句読点を打ち直す。そこで差を付けても製品の品質と対応
しない。生に近い `cer_raw` も併記してあるので、「句読点を出さないことで得をしただけ」の順位は
見分けられる。

**置換・挿入・削除の内訳を出す。**
Whisper 系は無音にテキストを幻覚する（挿入）、TDT 系は語を落とす（削除）という別の壊れ方をする。
会議の書き起こしはこの後 LLM がサマリを書くので、**落ちた語は復元できないが、混入した語は事実として
要約に書かれうる**。総 CER が同じでも意味が違う。

**reference は発話通りに書く（フィラーを含む）。**
Whisper 系は聞こえた音ではなく書き言葉として自然な形を出す傾向がある。実測でも
`お疲れさまでーす / あっ / いえいえいえ` が `お疲れ様です / いえいえ` になった。発話通りを正解に
すると、この整理は削除として計上される。それでよい。**2 段目の出力は LLM 整形の入力**であり
（design 33 MT12「表記正規化は整形の既存責務」）、raw の段階で勝手に整えられていることは長所とは
限らない。内訳の `del` を見れば「落としたのか、整えたのか」は区別できる。

**ベースラインは `AsrManager` ではなく `BatchAsrDecoder` を通す。**
評価対象は「製品が出す品質」なので、15 秒超の無音分割（`splitForSingleWindowDecode`）と CJK 対応の
連結を含んだ本番の経路で測る。素の `AsrManager` を測るとユーザーが体験しない数字になる。

## reference（正解）の作り方

`review.py --build` が全モデルの出力を並べたシートを作る。モデル間で食い違っている箇所が精度差の
出どころなので、そこだけ聞き直せばよい。reference ブロックの初期値は既定で WhisperKit の出力。

初期値を評価対象のどれかにするとその分だけ甘くなる。気になる場合は、比較に入っていないモデルで
下書きを作る:

```bash
tools/asr-eval/runners/qwen3_draft.sh          # MLX / Qwen3-ASR。比較対象ではなく下書き専用
python3 tools/asr-eval/review.py --build --draft qwen3_draft
```

## モデルを追加する

- FluidAudio の `AsrModelVersion` で表せるもの → `KIKIMI_ASR_EVAL_MODEL` に名前を足すだけ
  （`KikimiTests/Stt/AsrEvalHarness.swift`）
- 別パイプラインのもの → `AsrEvalCohereHarness.swift` を雛形に 1 ファイル追加
- CLI で回すもの → `runners/` にスクリプトを足して `hyp/<名前>/clip_NN.txt` を書く。
  `score.py` と `review.py` は `hyp/` のサブディレクトリを自動で拾う
