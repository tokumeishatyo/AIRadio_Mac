# S20 — .app バンドル化（ダブルクリック起動）

> 仕様駆動ワークフロー（CLAUDE.md §7）の SoT。**実装前にユーザーレビューを受ける**（§9 の設計判断を要確認）。
> 要件 §11／HANDOVER §11 の「署名 .app バンドル化・配布（後回し）」の着手分。**このスライスは「このMac専用・アドホック署名」スコープ**。

## 1. 概要

現状は `swift run AIRadioApp` で CLI 起動。これを **ダブルクリックで起動する `ケイラボAIラジオ.app`** にする。

- **配布形態**: `ケイラボAIラジオ/` という**1フォルダ**に `ケイラボAIラジオ.app` と `config/` を同梱（自己完結）。
  **フォルダごと削除すれば完全アンインストール**（消し漏れなし）。＊ユーザー判断：Application Support は .app 削除後に必ずフォルダが残る＝消し漏れになるため不採用。
- **署名**: アドホック（無料・このMac専用）。Gatekeeper は初回のみ「右クリック→開く」。
- **アイコン**: デフォルト（メニューバーは📻のまま・Finder は標準アイコン。後で .icns 差し替え可）。
- **動作前提は不変**（BYO・要件§1）: VOICEVOX 起動／Spotify 起動＋Premium／OAuth 認証済み／Gemini キー。

## 2. 核心：config パスの解決（最大の壁）

現状、config は cwd 相対の `"config/X.yaml"` がハードコード（BroadcastWiring ~20・MenuBar 2・main ~10 箇所）。ダブルクリック起動は cwd が `/` になり相対パスが解決できない。→ **config ベースディレクトリを解決する仕組み**を入れる。

### 2.1 解決ロジック（優先順）
1. 環境変数 `AIRADIO_CONFIG_DIR` があればそれ（明示上書き。CI・特殊運用用）。
2. `.app` バンドル内で動いている（`Bundle.main.bundleURL.pathExtension == "app"`）なら **`<.app の親ディレクトリ>/config`**（＝.app と同じ階層の config/）。
3. それ以外（dev `swift run`／直接実行）は **cwd 相対 `config`**（＝現行どおり。挙動不変）。

### 2.2 実装
- **純ロジックは Infra に置いてテスト**: `ConfigLocation.resolve(envOverride:appBundleParent:) -> String`（pure・3分岐）。`AIRadioInfra` に追加し単体テスト。
- **App グルー**: `AIRadioApp` に薄いヘルパ `func configPath(_ name: String) -> String`。
  `Bundle.main.bundleURL.pathExtension == "app"` なら親ディレクトリを渡し、そうでなければ nil を渡して `ConfigLocation.resolve` を呼び、`<base>/name` を返す。
- 全ハードコード `"config/X"` を `configPath("X")` に置換（BroadcastWiring・MenuBar・main）。
- 既存 `swift run`／テストは env 未設定＆非.app → `./config` で**挙動不変**。

## 3. .app バンドル構成

```
ケイラボAIラジオ/                         ← 配布フォルダ（このフォルダごと配置・削除で完全アンインストール）
├── ケイラボAIラジオ.app
│   └── Contents/
│       ├── Info.plist
│       └── MacOS/AIRadioApp             ← release ビルドの実行ファイル
└── config/                             ← .app と同じ階層。ユーザー編集可・秘密もここ
    ├── tts.yaml / themes.yaml / program.yaml / corners.yaml / djs.yaml /
    │   research.yaml / calendar.yaml / artists.yaml / artist-gen.yaml /
    │   pronunciations.yaml / llm.yaml …（デフォルト一式）
    ├── *.local.yaml                     ← 秘密（llm.local / spotify.local）。ユーザーのキー
    └── journal.local.yaml               ← 実行中に生成（長期記憶）
```

### Info.plist（最小）
- `CFBundleName` = `ケイラボAIラジオ`、`CFBundleExecutable` = `AIRadioApp`
- `CFBundleIdentifier` = `io.github.tokumeishatyo.airadio`（reverse-DNS。実ドメイン不要。変更可）
- `CFBundleShortVersionString` = `1.0` / `CFBundleVersion` = `1`
- **`LSUIElement` = `true`**（メニューバー常駐・Dock に出さない。既存 `setActivationPolicy(.accessory)` と合致）
- `LSMinimumSystemVersion` = `13.0`
- `NSHumanReadableCopyright` = VOICEVOX クレジット等

## 4. パッケージスクリプト `scripts/make-app.sh`

1. `swift build -c release` → `.build/release/AIRadioApp`
2. `dist/ケイラボAIラジオ/ケイラボAIラジオ.app/Contents/{MacOS,Info.plist}` を組み立て・実行ファイルをコピー
3. `./config` を `dist/ケイラボAIラジオ/config` にコピー（**このMac専用なので秘密込みで“すぐ動く”状態に**）。
   - ⚠️ 生成される `dist/` フォルダは **API キーを含む**ので**共有しない**。`--no-secrets` で `*.local.yaml` を除外する任意オプションを用意。
4. **アドホック署名**: `codesign --force --options runtime --sign - "…/ケイラボAIラジオ.app"`
5. 実行ファイルの依存確認（`otool -L`）= システムフレームワークのみ（Swift ランタイムは OS 同梱・ABI 安定、Yams は静的リンク）であることを前提に self-contained。
6. 完了メッセージ（初回は Finder で**右クリック→開く**が必要な旨／VOICEVOX・Spotify 起動の前提）。

- `.gitignore` に `dist/` を追加。

## 5. 署名・Gatekeeper・Keychain

- **アドホック署名**（`--sign -`）。Developer ID・notarization なし。
- 初回起動: Gatekeeper「開発元未確認」→ **右クリック→開く**（または システム設定→プライバシーとセキュリティ→このまま開く）で 1 回許可 → 以降ダブルクリック。
- **Keychain**（Spotify refresh token、service `AIRadio.Spotify`）: 既存トークンは同一ユーザー Keychain にあるが、ACL は署名ごと。.app 初回アクセス時に「常に許可」を 1 回押せば以降読める。
  - アドホック署名は内容ハッシュベースのため**コード変更（再ビルド）で署名が変わり再プロンプトの可能性**あり。安定 identity が要るなら Developer ID（将来・要件§11）。当面は許容。

## 6. Spotify ログイン手段（§9-A の設計判断）

現状、初回 OAuth ログインは CLI 専用（`AIRADIO_DEMO=spotify-auth`）。標準の .app には無いため、トークンが無効化（PKCE refresh ローテーションで invalid_grant 等）したとき .app だけでは再ログインできない。

→ **推奨**: メニューに **「Spotify にログイン」** 項目を追加（既存 `SpotifyAuth`＋`LoopbackServer` の PKCE フローを再利用。放送停止中のみ有効）。これで .app が自己完結する。
- 含めない場合: 既存 Keychain トークンが生きている限り .app は動くが、失効時はソースツリーから `swift run` で再ログインが必要（自己完結しない）。

## 7. スコープ外（S20）

- Developer ID 署名・notarization（他人配布。要件§11 将来）／カスタムアイコン（.icns）／.dmg 作成／自動アップデート／VOICEVOX・Spotify の自動起動（要件§11 後回し）。

## 8. テスト（`swift test` グリーンが完了条件）

- `ConfigLocation.resolve(envOverride:appBundleParent:)`（Infra・pure）:
  - env 指定があれば最優先で返す。
  - env なし・`appBundleParent` あり → `<parent>/config`。
  - env なし・`appBundleParent` nil（dev）→ `config`（cwd 相対）。
- 既存テストは挙動不変（config パス置換は App 層のみ・loader 群のシグネチャは不変）。
- App 層（Bundle.main 依存のグルー・make-app.sh・Info.plist）はユニットテスト対象外＝**ライブ確認**（§の受け入れ基準）。

## 9. 設計判断（要ユーザー確認 — レビューで確定）

- **A. Spotify ログインメニュー**（§6）: 追加する（推奨・.app が自己完結）／ 当面は既存 Keychain トークン頼みで追加しない。
- **B. config 同梱の秘密**: `make-app.sh` は既定で `./config` を秘密込みコピー（このMac専用・すぐ動く）。`--no-secrets` オプションも用意。この既定でよいか。
- **C. Bundle Identifier**: `io.github.tokumeishatyo.airadio`（変更可）。
- **D. アンインストール方針**: 「`ケイラボAIラジオ/` フォルダごと削除」で完全削除（Application Support 不使用）。＊ユーザー判断済み。

## 10. 受け入れ基準（ライブ確認）

1. `scripts/make-app.sh` 実行 → `dist/ケイラボAIラジオ/`（.app＋config）が生成される。
2. Finder で `ケイラボAIラジオ.app` を**右クリック→開く**（初回）→ メニューバーに 📻 が出る（Dock には出ない）。
3. メニューから「放送を開始」→ VOICEVOX で DJ が喋り、Spotify の曲が流れる（cwd に依存せず config を解決できている）。
4. 「アーティスト一覧を生成」→ `dist/ケイラボAIラジオ/config/artists.yaml` が更新される（書き込み先も解決できている）。
5. `swift run AIRadioApp`（開発）は従来どおり `./config` で動く（挙動不変）。
6. `ケイラボAIラジオ/` フォルダを削除 → 残骸なし（完全アンインストール）。
