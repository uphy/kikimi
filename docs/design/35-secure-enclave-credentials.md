# 35. Secure Enclave による credential 保管 詳細設計

`docs/design/26-settings-ui.md` §2 で導入した `KeychainCredentialStore`（macOS Keychain の generic
password）を、Secure Enclave のハードウェア鍵で暗号化したファイル保管に置き換える。

## 1. 背景と動機

ローカル開発ビルドでは、ビルドし直すたびに「Kikimi がキーチェーンに含まれるキー
"io.github.uphy.Kikimi" へアクセスしようとしています」ダイアログが出る。「常に許可」を押しても
次のビルドでまた出る。

真因は Keychain 項目 ACL の **partition list**。これは ACL の「アプリ一覧（trusted application）」とは
独立した第二の関門で、署名の **TeamIdentifier**（`teamid:XXX`）で照合される。自己署名証明書は
TeamIdentifier を持てない（`codesign` は Apple ルートにチェーンする証明書からしか Team ID を抽出せず、
証明書への OU 追加や Developer ID marker OID の付与では突破できない）。そのため照合が
**ビルドごとに変わる cdhash にフォールバック**し、毎回不一致になる。「常に許可」は partition list に
そのビルドの cdhash を 1 個追記するだけで、次のビルドでは再び一致しない。

検証で棄却した対策:

- **証明書のコード署名信頼登録（`security add-trusted-cert`）** — 効果なし。信頼は ACL のアプリ一覧側の
  照合を安定させるだけで、partition list には関与しない
- **decrypt ACL の「全アプリ許可」化（`SecAccess` の application list を nil にする）** — login キーチェーン
  では効果なし。partition list が独立して残るため。`security create-keychain` で作った一時キーチェーンには
  partition list ACL エントリがそもそも作られないので無音に見えるが、**この検証は login キーチェーンで
  行わないと誤った結論になる**
- **data protection keychain（`kSecUseDataProtectionKeychain`）** — 必要な
  `com.apple.application-identifier` は restricted entitlement で、provisioning profile なしで付けると
  プロセスが SIGKILL される

partition list はアプリ側の API から制御できず、`security set-generic-password-partition-list` で
ログインパスワードを入力する操作でしか触れない。恒久的にプロンプトを消すには Keychain 自体をやめるほかない。

## 2. 方針

API キーを Secure Enclave の P-256 鍵で暗号化し、`~/.local/state/kikimi/credentials/` 配下のファイルに
保存する。Keychain は使わない。

**生体認証（Touch ID）は付けない**。SE 鍵の `accessControl` を指定しないことで、復号は完全に無音になる。

得られる保護:

| 攻撃 | 結果 |
|---|---|
| 暗号文ファイルを他の Mac に持ち出す | 復号不可（SE 鍵の封印 blob はその Mac の Secure Enclave でしか復元できない） |
| 同一 Mac・同一ユーザー権限の別プロセスがファイルを読む | 復号可能 |

後者を許容する。これは `gh` / `aws` CLI 等が `0600` の dotfile に平文トークンを置くのと同水準であり、
少なくとも「設定ファイルへの平文直書き」よりは持ち出し耐性の分だけ強い。この水準を本アプリの受容基準とする。

**拡張ポイント**: 同一 Mac の他プロセスからも守りたくなった場合、SE 鍵生成時に `SecAccessControlCreateWithFlags`
で `[.privateKeyUsage, .userPresence]` を与えれば、復号のたびに Touch ID / パスワードが要求される。
鍵の属性は生成時に固定されるため、切り替えには鍵の再生成と暗号文の再暗号化（＝再入力または旧鍵での復号→新鍵で
再封印）が要る。今は実装しない。

## 3. 構成

Secure Enclave は実機（Apple Silicon / T2）でしか動かず、単体テストから触りたくない。そこで
**暗号操作**と**ファイル I/O・移行ロジック**を分離し、前者だけを protocol seam にする
（`HTTPTransporting` / `LLMProcessRunner` と同じパターン）。

```swift
/// Authenticated encryption over an opaque context string (the credential's account). Exists so
/// `EncryptedFileCredentialStore`'s file I/O and migration logic can be unit-tested without touching
/// the real Secure Enclave, which is unavailable in CI and would persist hardware-backed state.
protocol CredentialCipher: Sendable {
    func seal(_ plaintext: Data, context: String) throws -> Data
    func open(_ ciphertext: Data, context: String) throws -> Data
}
```

- `SecureEnclaveCipher` — production 実装
- `EncryptedFileCredentialStore` — `CredentialStoring` 実装。cipher とディレクトリを注入
- `DefaultCredentialStore.shared` — production の合成点。SE が使えなければ Keychain にフォールバック
- `KeychainCredentialStore` — 移行元としてのみ残す（新規書き込みには使わない）
- `InMemoryCredentialStore` — テスト用。変更なし

### 3.1 暗号方式

SE の P-256 鍵は署名（`SecureEnclave.P256.Signing`）か鍵合意（`KeyAgreement`）しかできず、直接データを
暗号化できない。したがって ECIES 相当の構成をとる。

**seal**:

1. ephemeral な `P256.KeyAgreement.PrivateKey`（ソフトウェア鍵）を生成
2. ephemeral 秘密鍵と SE 鍵の公開鍵で鍵合意 → `SharedSecret`
3. HKDF-SHA256 で 32 バイトの対称鍵を導出。`salt` は固定文字列、`sharedInfo` は `context`（account 名）
4. `ChaChaPoly.seal` で平文を封印
5. 出力 = `ephemeral 公開鍵の x963Representation`（65 バイト）+ `ChaChaPoly.SealedBox.combined`

**open** は 1 の代わりに先頭 65 バイトから ephemeral 公開鍵を復元し、SE 秘密鍵と鍵合意して同じ対称鍵を導出する。

`sharedInfo` に account を含めるので、ある account の暗号文を別の account のファイルに置いても復号は失敗する
（`ChaChaPoly` の認証タグ検証で弾かれる）。

### 3.2 ファイルレイアウト

```
~/.local/state/kikimi/credentials/   (0700)
├── se-key                            (0600) SE 秘密鍵の dataRepresentation（封印 blob）
└── llm.openai.api_key.enc            (0600) 暗号文
```

`se-key` は秘密鍵そのものではなく、Secure Enclave が自分だけ復元できる形に封印した blob。他の Mac に
コピーしても `PrivateKey(dataRepresentation:)` が失敗する。

暗号文のファイル名は account をサニタイズして使う（`[A-Za-z0-9._-]` 以外を `_` に置換）。account は
config.yaml のキーパス（`llm.openai.api_key`）なのでパス区切りを含まないが、ディレクトリ脱出を構造的に
防ぐために通す。

### 3.3 鍵のライフサイクル

`se-key` が無ければ生成して保存する。**この鍵を失うと暗号文は復号できない**（＝ API キーの再入力が必要）。
`se-key` はあるが暗号文の復号に失敗する場合（鍵とファイルの不整合、ファイル破損）は `read` が `nil` を返し、
設定画面で再入力できる状態に落ちる。credential は再取得可能な派生データなので、これを「壊れたら鍵ごと
作り直す」のではなく「読めない＝未設定として扱う」に倒す。

### 3.4 Keychain からの移行

`read(account:)` が暗号文ファイルを見つけられなかったとき、legacy store（`KeychainCredentialStore`）を
読みに行く。値があれば SE 側に書き、Keychain 項目を削除して、その値を返す。

移行時の Keychain 読み取りで**最後に 1 回だけ**ダイアログが出る。これは許容する（`docs/design/26-settings-ui.md`
§2 の判断を引き継ぐ）。以降は Keychain に触れないので二度と出ない。

移行に失敗しても（ユーザーがダイアログで拒否した、書き込みが失敗した）例外は投げず、`nil` または読み出せた値を
返して次回の `read` で再試行する。`AppConfig` の `migrateAPIKeyToKeychainIfNeeded()` と同じ「観測したら閉じる、
失敗したら次回」の方針。

### 3.5 Secure Enclave が使えない環境

`SecureEnclave.isAvailable == false`（Intel Mac の一部）では `DefaultCredentialStore.shared` が
`KeychainCredentialStore` を返す。従来どおり動作し、自己署名ビルドではダイアログが出続けるが、
Team ID 付きで署名された配布ビルドでは partition list が安定するので無音になる。フォールバックしたことは
`warning` ログに残す。

## 4. 注入箇所

`KeychainCredentialStore.shared` を既定値にしていた箇所を `DefaultCredentialStore.shared` に置き換える。

- `Kikimi/Config/AppConfig.swift` — `AppConfig()` / `init(directory:credentialStore:)`
- `Kikimi/ViewModels/SettingsViewModel.swift` — `init(...)`
- `Kikimi/LLM/OpenAIChatBackend.swift` — `init(...)`

加えて、**backend の生成が credential store を読んではならない**。`OpenAIChatBackend` は API キーを
`init` で eager に解決していたため、単に backend を作るだけで実 credential store に触れていた。これは
副作用のある操作で、§3.4 の Keychain 移行（と最後の 1 回のダイアログ）まで引き起こす。実際、

- `LLMClientTests` の `makeBackend(from:)` テストが実 Keychain を読み、開発機で OS のダイアログを出した
- `llm.provider: openai` の環境では、`LLMClient.shared` に触れるあらゆるテストが実 credential へ到達し、
  `swift test` が本物の API キーを Keychain から SE へ移行してしまった

対策は 2 つ。両方入れる。

1. `OpenAIChatBackend` の API キー解決を遅延させる（`LazyAPIKey`）。`init` は純粋になり、最初の
   `complete(_:)` でのみ credential store を読む。プロセスあたり高々 1 回という §3.2 の性質は保つ
2. `makeBackend(from:credentialStore:)` に seam を足し、テストは `InMemoryCredentialStore()` を渡す

## 5. テスト方針

レイヤ 1（`swift test`）は実 Secure Enclave にも実 Keychain にも触れない。

- `EncryptedFileCredentialStore` — 一時ディレクトリ + fake cipher（`CredentialCipher` のテスト実装）で
  往復・上書き・削除・不在時 `nil`・account ごとの独立性・移行（fake legacy store）・移行失敗時の挙動を検証
- ファイルパーミッション（0600 / 0700）とサニタイズ結果も一時ディレクトリ上で検証できる
- `SecureEnclaveCipher` 自体は実機依存なのでレイヤ 1 では検証しない。往復動作は CLI で実証済み。
  アプリ組み込み後の確認はレイヤ 2/3（ユーザーによる UI 動作確認）で行う

## 6. kikimi.md との整合

kikimi.md 12 章の config/state 分離に従い、credential は state 側（`~/.local/state/kikimi/`）に置く。
config.yaml には引き続き平文の API キーを永続化しない（`docs/design/26-settings-ui.md` §3.1 の
`migrateAPIKeyToKeychainIfNeeded()` はそのまま動き、移行先が Keychain から SE に変わるだけ）。
