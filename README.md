# Kikimi（聞き耳）

会議特化のリアルタイム書き起こし macOS アプリ。詳細な製品仕様は [`kikimi.md`](kikimi.md) を参照。

## インストール

```bash
brew install uphy/tap/kikimi
```

macOS 14 (Sonoma) 以降が必要。メニューバー常駐アプリなので Dock にアイコンは出ない。初回起動時に
マイクとシステム音声の録音許可を求め、オンデバイス音声認識モデルを
`~/Library/Application Support/FluidAudio` にダウンロードする。

整形・サマリは LLM を呼ぶ。既定のプロバイダは `claude` CLI（`brew install claude-code`）で、
`~/.config/kikimi/config.yaml` に `llm.provider: openai` を書けば OpenAI API キーでも動く。

配布物は Developer ID 署名・notarization を行っていないため、cask のインストール時に quarantine 属性を
外している（詳細は `brew info --cask uphy/tap/kikimi` の caveats）。

## リリース

`v*` タグを push すると [`.github/workflows/release.yml`](.github/workflows/release.yml) が lint・テスト →
`.app` ビルド → バンドル検証 → zip → draft リリース作成 → [uphy/homebrew-tap](https://github.com/uphy/homebrew-tap)
の `Casks/kikimi.rb` 更新 → リリース公開までを行う。tap 更新が失敗しても、ユーザーから見える成果物は
残らない（公開は最後の 1 ステップ）。`v1.2.3-rc.1` のようなプレリリースタグは GitHub Release だけを作り、
cask は動かさない。

```bash
git tag v0.1.0 && git push origin v0.1.0
```

## セットアップ・ビルド

Claude Code 向けの開発ルールは [`CLAUDE.md`](CLAUDE.md) を参照（`mise run generate`/`build`/`apply` 等の
タスク説明、TCC 権限が再ビルドで失効する問題への対処など）。

## トラブルシューティング

### Keychain アクセス確認ダイアログが毎回出る（解決済み）

API キー（`llm.openai.api_key`）を Keychain に保存していた頃、ビルドし直すたびにアクセス確認ダイアログが
表示され、「常に許可」を押しても直らない問題があった。**2026-07-10 に Secure Enclave 方式へ移行して解消**
（[`docs/design/35-secure-enclave-credentials.md`](docs/design/35-secure-enclave-credentials.md)）。

真因は Keychain 項目 ACL の **partition list**。ACL の「アプリ一覧」とは独立した第二の関門で、署名の
Team Identifier（`teamid:XXX`）で照合される。自己署名証明書は Team Identifier を持てない（codesign は
Apple ルートにチェーンする証明書からしか Team ID を抽出しない）ため、照合がビルドごとに変わる cdhash に
フォールバックし、毎ビルド不一致になっていた。「常に許可」は partition list にそのビルドの cdhash を
1 個追記するだけなので、次のビルドでまた出る。

効かなかった対策（再調査不要）:

- 証明書のコード署名信頼登録（`security add-trusted-cert`）— アプリ一覧側の照合にしか効かない
- Keychain 項目の ACL を「全アプリ許可」にする — partition list が独立して残るため login キーチェーンでは無効
  （一時キーチェーンには partition list がないので無音に見えるだけ。検証は login キーチェーンで行うこと）
- data protection keychain — `com.apple.application-identifier` が restricted entitlement で、
  provisioning profile なしだとプロセスが SIGKILL される

現在は API キーを Secure Enclave の P-256 鍵で暗号化し、`~/.local/state/kikimi/credentials/` 配下に
`0600` で保存している。Keychain は使わないのでダイアログは出ない。暗号文を他の Mac に持ち出しても
復号できない（鍵はその Mac の Secure Enclave からしか復元できない）。生体認証は付けていないため、
同一 Mac・同一ユーザー権限のプロセスからは復号可能で、保護水準は `gh` / `aws` CLI 等の `0600` dotfile と同等。

初回起動時、Keychain に残っている旧項目を読み出して自動的に移行する。**このとき最後に 1 回だけ
アクセス確認ダイアログが出る**ので「許可」を押す。移行後、旧項目は削除され、以降は二度と出ない。
