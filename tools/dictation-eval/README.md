# dictation-eval

ディクテーション整形プロンプト（`PromptSpec.dictationDefaultBody`）の A/B 用オフライン評価。
主眼は**言い直し（自己修正）の断片が消えるか**で、過剰削除・応答してしまう退行も同時に見る。

`tools/asr-eval/` が音声認識モデルを比べるのに対し、こちらは書き起こし後の LLM 整形だけを対象にする。

## 使い方

エンドポイント（`base_url` / `api_version` / `model` / `reasoning_effort`）は
`~/.config/kikimi/config.yaml` の `llm.providers.openai` から自動で読む。渡すのは API キーだけ。
キー本体は Secure Enclave 鍵で暗号化された `~/.local/state/kikimi/credentials/` にあり、
このスクリプトからは復号できないため。

```bash
export KIKIMI_EVAL_API_KEY='...'   # または --api-key-file <path>

# 現在の PromptSpec.swift の本文で採点
python3 tools/dictation-eval/eval.py run --out /tmp/after.json

# 変更前の本文と比べる（--body-rev がその git リビジョンの PromptSpec.swift から本文を取る）
python3 tools/dictation-eval/eval.py run --body-rev HEAD --out /tmp/before.json
python3 tools/dictation-eval/eval.py compare /tmp/before.json /tmp/after.json

# 送っているプロンプトの確認（API を叩かない）
python3 tools/dictation-eval/eval.py run --print-prompt
```

config.yaml の値を上書きしたいときは `--base-url` / `--model` / `--api-version` / `--reasoning-effort`、
または対応する `KIKIMI_EVAL_*` 環境変数を使う。認証ヘッダの選び方は
`OpenAIChatBackend.resolveAuthHeaderKind` と同じ規則（`api_version` があれば `api-key`、無ければ Bearer）。

## 組み立てているプロンプト

production（`DictationRefiner.refine` → `DictationContextResolver.resolve`）と同じ並び。

```
DictationRefiner.preamble
  ↓
方針層本文（--body、既定は PromptSpec.swift の dictationDefaultBody を抽出）
  ↓
用語集ブロック（PromptSpec.glossaryHeaderDefaultBody + sample-glossary.md）
  ↓
DictationRefiner.outputFormatSuffix
```

本文は `.app` をビルドせずに Swift ソースから正規表現で取り出す。`Kikimi --render-prompt dictation`
を使わないのは、あれがビルド済み `.app` を要求するうえ、用語集を固定サンプルで差し込むため
A/B で用語集の量を動かせなくなるから。**`PromptSpec.swift` の定数名を変えたらここも直す。**

用語集は `sample-glossary.md`（ダミー用語のみ）。実運用の用語集は 79 件あり、system prompt の過半を
占める。この「量による希釈」自体が整形の効きに影響するので、件数を production に近づけてある。
`--no-glossary` で外せば希釈の寄与を切り分けられる。

## ケースと採点

`cases.json`。`raw` は `~/.local/state/kikimi/dictation/history/` の実発話で、社内固有名詞はダミーに
置き換えてある。

期待出力を1本の文字列で持たないのは、実際の言い淀みでは「理想の整形結果」が一意に決まらないため。
代わりに部分文字列で表明する。

| 表明 | 意味 |
|---|---|
| `must_not_contain` | 言い直し前の断片が残っていないこと |
| `must_contain` | 言い直し後の内容・重要語が消えていないこと |
| `max_count` | 同じ語句が指定回数を超えて残っていないこと |

LLM の出力はサンプリングでぶれるので、1 ケースを複数回試行し `OK`（全通過）/ `FLAK`（一部）/
`FAIL`（全滅）で表示する。exit code は全 run 通過なら 0。

**試行数は 10 以上にする。** 3 で回したところ、同一プロンプト・同一ケースの再実行で `0/3` と `3/3` の
両方が出た。ぶれがケース単位の差に匹敵するので、3 試行の増減は判断材料にならない。`compare` は
`trials < 10` のとき警告を出す。

レイテンシも p50 / p90 / max で出す。`dictation.refine_timeout_ms`（既定 3000）は打ち切りの実閾値で、
超えると raw text にフォールバックする。`--reasoning-effort` を上げるなど品質と遅延を交換する手を
試すときは、必ずこの数字と合わせて見る。

ケースの追加は、history に新しい失敗例が出たときに `raw` と表明を足すだけでよい。

### プロンプトの例文とケースの文面は重ねない

`dictationDefaultBody` の例文も `cases.json` の `raw` も、同じ実発話コーパスから採っている。片方の文面を
もう片方にそのまま持ち込むと、そのケースは「一般化できたか」ではなく「プロンプトに書いてある文を再現できたか」
を測ることになる。**プロンプトに例を足すときは、ケースと同じ型で違う文面にする。**

初版の A/B ではここを踏んでいて、`restart-from-top` と `duplicated-subject` の 2 ケースは例文と文面が
一致していた。現在の本文では書き換え済み。

## 実測結果（2026-08-03, gpt-5.4-mini, 10試行）

【言い直しの処理】ブロック導入の A/B と、そのあと測った `reasoning_effort` の効き。

| 条件 | スコア | p50 | p90 |
|---|---|---|---|
| 旧本文（言い直しが1 bullet） + effort=none | 63/100 | 1689ms | 2201ms |
| 現本文 + effort=none（採用） | 75/100 | 1685ms | 1994ms |
| 現本文 + effort=minimal | 79/100 | 1654ms | 2018ms |
| 現本文 + effort=low | 87/100 | 1920ms | 3245ms |

`effort=low` は `restart-from-top` を 0/10 → 10/10、`duplicated-subject` を 3/10 → 8/10 にする。
この2件は `none` では一貫して失敗するので、残る失敗の主因はプロンプトの語数ではなく推論量である。

**それでも `none` を採用している。** `low` は 14/100 の run が `refine_timeout_ms`（3000）を超え、
その発話は整形が丸ごと効かず raw text にフォールバックするため。句読点も用語集も同音誤変換の修正も
失う代償は、言い直し検出の改善に見合わない。

採用するなら、プロバイダ全体の `reasoning_effort` ではなくディクテーション専用の model alias に載せる
（サマリ・Watcher・チャットを巻き込まないため）。`llm.models.<alias>` の `timeout_seconds` は
`DictationRefiner.refine` が `max(refine_timeout_ms, timeout_seconds*1000)` で効かせるので、
待ち時間の許容が変わったときはこの1箇所で両方決まる。

```yaml
llm:
  models:
    dictation: { provider: openai, model: gpt-5.4-mini, effort: low, timeout_seconds: 5 }
dictation:
  model: dictation
```

`effort=minimal` の +4 はノイズと区別がつかない（100試行の二項標準誤差が約4ポイント）。レイテンシも
`none` と変わらないので、`minimal` は `none` に対してほぼ何もしていないと見てよい。
